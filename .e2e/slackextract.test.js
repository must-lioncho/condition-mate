// E2E for 번역함 ⋮ 메뉴의 "세션 추출" — 단순 추출 / 컨텍스트 공유하기.
// slackmenu.test.js 와 같은 방식으로 SlackTranslateContent.swift 에서 실제 페이지
// HTML(CSS+JS)을 통째로 뽑아 진짜 Chromium 에서 돌린다 (스텁은 /api/slack/items 뿐).
//
// 검증 대상:
//   1) 세션이 없는 항목의 ⋮ 에는 단순 추출 · 컨텍스트 공유하기 두 갈래가 있다.
//   2) 컨텍스트 공유하기는 목표 입력 패널을 열고, 목표가 비면 아무 일도 하지 않는다.
//   3) 목표를 넣고 시작하면 goal-add 로 넘어가며 (a) 첫 턴 초안 맨 앞에 [목표] 가 박히고
//      (b) 목표 원문이 cm.gaSlackGoal 로 실리고 (c) URL 에 slackCtx=1·preset=slack·
//      짧은 제목(gtitle)이 실린다 — 이 셋이 goal-add 쪽 수집/프리앰블/제목의 입력이다.
//   4) 이미 세션이 연결된 항목(cache.gui)은 두 갈래 대신 "세션 이어가기"만 보인다.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/Plugins/Slack/SlackTranslateContent.swift', 'utf8');
const open = SRC.indexOf('return #"""');
if (open < 0) throw new Error('페이지 HTML 리터럴을 못 찾음');
const html = SRC.slice(open + 'return #"""'.length, SRC.indexOf('"""#', open))
  .replace('\\#(headExtraHTML())', ''); // 호스트 앱 주입분 — 페이지 자체 폴백 사용

const now = Math.floor(Date.UTC(2026, 7, 22, 2, 42) / 1000);
const item = (n, extra) => Object.assign({
  id: 'C1:' + n, channel: 'C1', channelName: '그룹 DM · cardinal, iris',
  author: 'Hamilton Ude', reactedAt: now - n * 600,
  textEn: 'Developers increasingly rely on AI to execute multi-step work #' + n,
  textKo: '개발자들은 다단계 작업을 위해 점점 더 AI에 의존합니다 #' + n,
  meaning: '시장의 페인 포인트를 구체화하는 메시지',
  decision: '1) 문제 정의서에 반영 2) 검증 회의 제안',
  permalink: 'https://slack.example/archives/C1/p' + n,
}, extra || {});
const base = {
  items: [item(1), item(2), item(3)],
  done: {}, syncErr: {}, replies: {}, gui: {},
  model: 'gemini-flash-lite', lang: 'ko', geminiKey: true, debugButtons: false,
};

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

const ROW = '#list .item[data-id="C1:2"]';
const menuLabels = page => page.evaluate(sel => {
  const menu = document.querySelector(sel).querySelector(':scope > .acts .menu');
  return Array.prototype.map.call(menu.children, c => c.textContent.trim());
}, ROW);

async function boot(browser, payload) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
  await page.addInitScript(p => {
    window.fetch = u => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(String(u).indexOf('/api/slack/items') >= 0 ? p : {}),
    });
  }, payload);
  await page.route('http://cm.test/**', r =>
    r.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
  await page.goto('http://cm.test/slack-translate');
  await page.waitForSelector('#list .item');
  return page;
}

(async () => {
  const browser = await chromium.launch();

  // ---- 세션이 없는 항목: 두 갈래가 보인다 ----
  const page = await boot(browser, base);
  await page.$eval(ROW + ' > .acts .menu-wrap > button', b => b.click());
  const labels = await menuLabels(page);
  check('⋮ 메뉴에 "세션 추출" 구분이 생긴다', labels.includes('세션 추출'), JSON.stringify(labels));
  check('단순 추출이 있다', labels.includes('단순 추출'));
  check('컨텍스트 공유하기가 있다', labels.includes('컨텍스트 공유하기'));
  check('기존 항목(슬랙에서 열기·처리완료)은 그대로', /슬랙에서 열기/.test(labels[0]) && /처리완료/.test(labels[1]));

  // ---- 컨텍스트 공유하기 → 목표 입력 패널 ----
  await page.click(ROW + ' .menu button:has-text("컨텍스트 공유하기")');
  await page.waitForSelector(ROW + ' .ctx-box');
  const panel = await page.evaluate(sel => {
    const it = document.querySelector(sel);
    const box = it.querySelector('.ctx-box');
    const r = box.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + 6);
    return {
      collapsed: it.classList.contains('collapsed'),
      guarded: box.classList.contains('reply-box'),   // 폴링 재렌더 가드가 같이 지켜 준다
      hasTextarea: !!box.querySelector('textarea'),
      visible: !!(hit && hit.closest('.ctx-box') === box),
      h: Math.round(r.height),
    };
  }, ROW);
  check('패널이 열리면 항목은 펼쳐져 있다', panel.collapsed === false);
  check('목표 입력칸이 있다', panel.hasTextarea === true);
  check('패널이 실제로 화면에 보인다 (클리핑 없음)', panel.visible === true, panel.h + 'px');
  check('재렌더 가드(.reply-box)를 함께 단다', panel.guarded === true);

  // 목표가 비면 시작하지 않는다 (빈 세션이 만들어지면 목표 없는 골만 남는다).
  await page.click(ROW + ' .ctx-box .send');
  await page.waitForTimeout(300);
  check('목표가 비면 넘어가지 않는다', /slack-translate$/.test(page.url()), page.url());
  check('패널은 그대로 남는다', await page.$$eval(ROW + ' .ctx-box', b => b.length === 1));

  // ---- 목표를 넣고 시작 ----
  const GOAL = '이 제품 방향이 맞다는 걸 인정받고 다음 주 검증 회의를 잡는다';
  await page.fill(ROW + ' .ctx-box textarea', GOAL);
  await page.click(ROW + ' .ctx-box .send');
  await page.waitForURL(/goal-add/);
  const url = new URL(page.url());
  check('goal-add 로 넘어간다', url.pathname === '/goal-add');
  check('slackCtx=1 (원 대화 수집 신호)', url.searchParams.get('slackCtx') === '1');
  check('preset=slack (대화 대응 프리앰블)', url.searchParams.get('preset') === 'slack');
  check('start=1 (자동 시작)', url.searchParams.get('start') === '1');
  check('slackId 로 원 메시지를 잇는다', url.searchParams.get('slackId') === 'C1:2');
  check('제목은 목표 한 줄로 짧게', url.searchParams.get('gtitle') === 'Slack 대응: ' + GOAL.slice(0, 50),
    url.searchParams.get('gtitle'));

  const stored = await page.evaluate(() => ({
    draft: localStorage.getItem('cm.gaDraft') || '',
    goal: localStorage.getItem('cm.gaSlackGoal') || '',
  }));
  check('목표 원문이 서버로 갈 자리에 담긴다', stored.goal === GOAL, stored.goal);
  check('첫 턴 초안 맨 앞이 [목표]', stored.draft.startsWith('[목표] ' + GOAL), stored.draft.slice(0, 40));
  check('초안에 대상 메시지 원문이 실린다', stored.draft.includes('개발자들은 다단계 작업을 위해'));
  check('초안에 의미 분석·의사결정이 실린다',
    stored.draft.includes('[의미 분석]') && stored.draft.includes('[의사결정 선택지]'));
  check('초안에 슬랙 링크가 실린다', stored.draft.includes('https://slack.example/archives/C1/p2'));
  await page.close();

  // ---- 이미 세션이 연결된 항목 ----
  const linked = await boot(browser, Object.assign({}, base, { gui: { 'C1:2': { seq: 7, at: now } } }));
  await linked.$eval(ROW + ' > .acts .menu-wrap > button', b => b.click());
  const l2 = await menuLabels(linked);
  check('연결된 항목엔 "세션 이어가기 (goal-07)"', l2.some(t => t === '세션 이어가기 (goal-07)'), JSON.stringify(l2));
  check('연결된 항목엔 단순 추출이 안 보인다', !l2.includes('단순 추출'));
  check('연결된 항목엔 컨텍스트 공유하기가 안 보인다', !l2.includes('컨텍스트 공유하기'));

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
