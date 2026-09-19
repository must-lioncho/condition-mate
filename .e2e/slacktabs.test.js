// E2E for the Slack 번역함 카드의 에이전트별 탭 + 스레드 묶음 (2026-08-31).
// 실제 소스에 묶인다 — SlackTranslateContent.swift 에서 페이지 HTML(CSS+JS)을 통째로
// 떼어내 진짜 Chromium 에서 돌리고, /api/slack/items 만 스텁한다 (slackmenu 와 같은 틀).
//
// 무엇을 지키는가:
//   1. 세 에이전트의 산출물이 한 덩어리로 이어지지 않고 탭으로 갈린다.
//   2. 의사결정 탭이 기본으로 열린다 — 라이언이 카드를 열자마자 결정할 수 있어야 한다.
//   3. 컨텍스트 탭에서 전달 여부와 **나간 언어**가 보인다.
//   4. 발신 탭에서 안 나간 건은 이유가 보이고 빈 화면이 아니다.
//   5. ackLang/ackBody 가 없는 옛 레코드에서도 깨지지 않는다.
//   6. 스레드 묶음은 기본 꺼짐이고, 켜면 같은 threadTs 가 한 묶음으로 모인다.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/Plugins/Slack/SlackTranslateContent.swift', 'utf8');
const open = SRC.indexOf('return #"""');
if (open < 0) throw new Error('페이지 HTML 리터럴을 못 찾음');
const html = SRC.slice(open + 'return #"""'.length, SRC.indexOf('"""#', open))
  .replace('\\#(headExtraHTML())', '');

const now = Math.floor(Date.UTC(2026, 7, 31, 5, 47) / 1000);

// 2026-08-31 야샬 스레드를 그대로 옮겼다 — 부모는 한국어(양호영), 답글은 영어(야샬).
const parent = {
  id: 'C0BN2351YG6:1788164273.559049', channel: 'C0BN2351YG6', channelName: '#ir-deck',
  ts: '1788164273.559049', author: 'Ho Young Yang (양호영)', authorId: 'U08JA6KNXMM',
  reactedAt: now - 900, textEn: 'IR-DECK 팀원 반영과 관련하여 마케팅 담당자 CMO 배치를 요청받았습니다.',
  textKo: 'IR-DECK 팀원 반영과 관련하여 마케팅 담당자 CMO 배치를 요청받았습니다.',
  meaning: 'IR Deck 에 포함할 마케팅(CMO) 포지션의 적임자를 찾는 요청이다.',
  decision: '1) 추천 인력 회신 2) 채용 진행 보류',
  ackTs: '1788164278.356929', ackAt: now - 890, ackLang: 'ko', ackLangBasis: 'roster:slack-profile',
  ackBody: '아만니 카누를 추천합니다. 필요한 이력 항목은 오늘 중 정리해 드리겠습니다.',
};
// 나간 건 — 영어. 이 카드에서 "영어로 나갔다"가 보여야 한다.
const sentEn = Object.assign({}, parent, {
  id: 'C0BN2351YG6:1788167773.300609', ts: '1788167773.300609', threadTs: '1788164273.559049',
  author: 'Yashal Nawaid (야샬)', authorId: 'U0BKH9ACC23', reactedAt: now - 120,
  textEn: 'More info: Akash Deshmukh is Crypto GTM / Growth Owner joining today.',
  textKo: '추가 정보: Akash Deshmukh 는 오늘 조인하는 Crypto GTM / Growth Owner 입니다.',
  meaning: '야샬이 신규 입사자 두 명의 상세 담당 업무를 추가 공유하고 있다.',
  decision: '1) 신규 입사자 배정 확정 2) 기존 후보 검토 유지',
  ackLang: 'en', ackLangBasis: 'roster:slack-profile', ackAt: now - 110,
  ackTs: '1788167779.115879',
  ackBody: 'Akash owns Crypto GTM and Al Rizqi owns SEA brand marketing from Sep 1.',
});
// 안 나간 건 — 사유가 보여야 하고 빈 화면이면 안 된다.
const blocked = {
  id: 'C2:9', channel: 'C2', channelName: '#chat-random-global', ts: '9',
  author: 'Someone', authorId: 'U9', reactedAt: now - 300,
  textEn: 'See you all at tea break soon.', textKo: '곧 티타임에서 뵈어요.',
  meaning: '가벼운 일정 공유다.', decision: '',
  ackBlockedAt: now - 290, ackBlockedReasons: ['NO_INFORMATION_GAIN'],
  ackLang: 'en', ackLangBasis: 'message', ackGrade: 'R2',
};
// 옛 레코드 — ackLang·ackBody·ack* 자체가 없다. 새 필드가 없어도 깨지면 안 된다.
const legacy = {
  id: 'C3:1', channel: 'C3', channelName: '#old', ts: '1',
  author: 'Old', authorId: 'U0', reactedAt: now - 86400,
  textEn: 'legacy row with no ack fields at all', textKo: '옛 레코드',
  meaning: '옛 의미 분석', decision: '옛 의사결정',
};

const PAYLOAD = {
  items: [sentEn, parent, blocked, legacy],
  done: {}, syncErr: {}, replies: {},
  model: 'gemini-flash-lite', lang: 'ko', geminiKey: true, debugButtons: false,
};

let pass = 0, fail = 0;
const check = (n, ok, extra) => {
  console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : ''));
  ok ? pass++ : fail++;
};

const bodyOf = (page, id) => page.evaluate(sel => {
  const it = document.querySelector(sel);
  const tabs = Array.prototype.map.call(it.querySelectorAll(':scope > .tabs button'), b => ({
    label: b.textContent.replace('●', '').trim(), on: b.classList.contains('on'),
  }));
  const tb = it.querySelector(':scope > .tabbody');
  return { tabs, text: tb ? tb.innerText : null, html: tb ? tb.innerHTML : '' };
}, `#list .item[data-id="${id}"]`);

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1100, height: 1200 } });
  await page.addInitScript(payload => {
    window.localStorage.removeItem('cm.slackGroup');
    // 이 테스트의 픽스처는 전부 ackAt 을 들고 있어 새 기본 세그(결정 대기)에는
    // 뜨지 않는다. 이 파일이 보려는 것은 탭·추출이지 세그가 아니므로 전체로 고정한다.
    // 세그 자체의 회귀는 SPEC P9 (SLKST-1..6) 이 따로 맡는다.
    window.localStorage.setItem('cm.slackFilter', 'all');
    window.fetch = u => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(String(u).indexOf('/api/slack/items') >= 0 ? payload : {}),
    });
  }, PAYLOAD);
  await page.route('http://cm.test/**', r =>
    r.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
  await page.goto('http://cm.test/slack-translate');
  await page.waitForSelector('#list .item');

  // 전부 펼친다 — 탭은 펼친 카드에서만 보인다 (접힘은 한 줄 요약 그대로).
  await page.click('#expBtn');
  await page.waitForSelector('#list .item .tabs');

  // ---- 1. 탭 셋, 의사결정이 기본 ----
  const t0 = await bodyOf(page, sentEn.id);
  check('탭이 셋이다', t0.tabs.length === 3, JSON.stringify(t0.tabs.map(t => t.label)));
  check('탭 이름이 의사결정·컨텍스트·발신',
    JSON.stringify(t0.tabs.map(t => t.label)) === JSON.stringify(['의사결정', '컨텍스트', '발신']));
  check('의사결정 탭이 기본으로 열린다', t0.tabs[0].on === true);
  check('기본 탭에는 의사결정만 보인다',
    t0.text.indexOf('신규 입사자 배정 확정') >= 0 && t0.text.indexOf('상세 담당 업무') < 0);

  // 한 덩어리로 이어지던 것이 실제로 갈렸는가 — 의미 분석과 의사결정이 동시에 보이면 실패.
  check('의미 분석과 의사결정이 한 화면에 함께 쌓이지 않는다',
    !(t0.text.indexOf('의미 분석') >= 0 && t0.text.indexOf('의사결정') >= 0), t0.text.slice(0, 60));

  // ---- 2. 컨텍스트 탭 — 읽은 컨텍스트 + 전달 여부 + 나간 언어 ----
  await page.click(`#list .item[data-id="${sentEn.id}"] > .tabs button:nth-child(2)`);
  const ctx = await bodyOf(page, sentEn.id);
  check('컨텍스트 탭으로 옮겨진다', ctx.tabs[1].on === true);
  check('컨텍스트 탭에 의미 분석이 있다', ctx.text.indexOf('상세 담당 업무') >= 0);
  check('컨텍스트 탭에 전달 여부가 있다', ctx.text.indexOf('슬랙에 전달됨') >= 0);
  check('컨텍스트 탭에 나간 언어가 English 로 보인다', ctx.text.indexOf('English') >= 0, ctx.text.replace(/\n/g, ' | '));

  // 한국어로 나간 카드는 같은 자리에 한국어라고 떠야 한다.
  await page.click(`#list .item[data-id="${parent.id}"] > .tabs button:nth-child(2)`);
  const ctxKo = await bodyOf(page, parent.id);
  check('한국어로 나간 건은 한국어로 표시된다',
    ctxKo.text.indexOf('한국어') >= 0 && ctxKo.text.indexOf('English') < 0);

  // ---- 3. 발신 탭 — 나간 본문 ----
  await page.click(`#list .item[data-id="${sentEn.id}"] > .tabs button:nth-child(3)`);
  const snd = await bodyOf(page, sentEn.id);
  check('발신 탭에 실제로 나간 본문이 있다', snd.text.indexOf('Akash owns Crypto GTM') >= 0);

  // ---- 4. 안 나간 건 — 사유가 보이고 빈 화면이 아니다 ----
  await page.click(`#list .item[data-id="${blocked.id}"] > .tabs button:nth-child(3)`);
  const blk = await bodyOf(page, blocked.id);
  check('안 나간 건은 안 나갔다고 말한다', blk.text.indexOf('슬랙에 나가지 않음') >= 0);
  check('안 나간 이유가 사람 말로 보인다', blk.text.indexOf('재진술') >= 0, blk.text.replace(/\n/g, ' | '));
  check('사유 코드도 함께 남는다', blk.text.indexOf('NO_INFORMATION_GAIN') >= 0);
  check('발신 탭이 빈 화면이 아니다', blk.text.trim().length > 20);

  // ---- 5. 옛 레코드 — 새 필드가 하나도 없어도 깨지지 않는다 ----
  const old = await bodyOf(page, legacy.id);
  check('옛 레코드도 탭 셋을 그린다', old.tabs.length === 3);
  check('옛 레코드 의사결정 탭이 비어 있지 않다', old.text.indexOf('옛 의사결정') >= 0);
  await page.click(`#list .item[data-id="${legacy.id}"] > .tabs button:nth-child(3)`);
  const oldSnd = await bodyOf(page, legacy.id);
  check('ack 기록이 아예 없는 옛 레코드도 빈 화면이 아니다',
    oldSnd.text.indexOf('나가지 않음') >= 0 && oldSnd.text.trim().length > 20,
    oldSnd.text.replace(/\n/g, ' | ').slice(0, 90));

  // ---- 6. 스레드 묶음 ----
  check('묶음은 기본 꺼짐', (await page.$$('#list .thgrp')).length === 0);
  await page.click('#grpBtn');
  await page.waitForSelector('#list .thgrp');
  const grouped = await page.evaluate(() => Array.prototype.map.call(
    document.querySelectorAll('#list .thgrp'),
    g => Array.prototype.map.call(g.querySelectorAll(':scope > .item'), i => i.dataset.id)));
  check('같은 스레드 두 건이 한 묶음으로 모인다',
    grouped.length === 1 && grouped[0].length === 2, JSON.stringify(grouped));
  check('묶음 안은 시각 오름차순 — 부모가 위에 온다',
    grouped[0] && grouped[0][0] === parent.id, JSON.stringify(grouped[0]));
  check('스레드가 아닌 건은 묶이지 않고 그대로 남는다',
    (await page.$$('#list > .item')).length === 2);
  // 묶음 안에서도 탭이 그대로 돈다 (thgrp 안의 .item 도 같은 카드다).
  await page.click(`#list .item[data-id="${parent.id}"] > .tabs button:nth-child(3)`);
  const inGroup = await bodyOf(page, parent.id);
  check('묶음 안에서도 탭이 동작한다', inGroup.tabs[2].on === true && inGroup.text.indexOf('아만니 카누') >= 0);

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
