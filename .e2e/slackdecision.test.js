// Slack 번역함 의사결정 카드: 1/2 클릭·숫자 키·3 직접 입력·Esc 중단.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/Plugins/Slack/SlackTranslateContent.swift', 'utf8');
const open = SRC.indexOf('return #"""');
if (open < 0) throw new Error('페이지 HTML 리터럴을 못 찾음');
const html = SRC.slice(open + 'return #"""'.length, SRC.indexOf('"""#', open))
  .replace('\\#(headExtraHTML())', '');

const item = {
  id: 'C1:1', channel: 'C1', channelName: '#decision', ts: '1', author: 'Tester',
  textKo: '어느 방향으로 진행할까요?', textEn: 'Which way?', reactedAt: 1,
  decision: '1) 첫 번째 안으로 진행한다\n2) 두 번째 안으로 진행한다',
};
const payload = { items:[item], done:{}, syncErr:{}, replies:{}, debugButtons:false };
let pass=0, fail=0;
const check=(name,ok,extra)=>{ console.log((ok?'PASS ':'FAIL ')+name+(extra?'  '+extra:'')); ok?pass++:fail++; };

(async()=>{
  const sent=[];
  const browser=await chromium.launch();
  const page=await browser.newPage();
  await page.addInitScript(payload=>{
    localStorage.setItem('cm.slackFilter','all');
    window.__payload=payload;
  },payload);
  await page.route('http://cm.test/**',async route=>{
    const req=route.request();
    if(req.url().endsWith('/api/slack/reply')){
      sent.push(JSON.parse(req.postData()));
      return route.fulfill({contentType:'application/json',body:'{"ok":true}'});
    }
    if(req.url().endsWith('/api/slack/items'))
      return route.fulfill({contentType:'application/json',body:JSON.stringify(payload)});
    return route.fulfill({contentType:'text/html; charset=utf-8',body:html});
  });
  await page.goto('http://cm.test/slack-translate');
  await page.click('#expBtn');
  const panel='#list .decision-panel';
  await page.waitForSelector(panel);
  check('1·2 선택지가 버튼으로 보인다',(await page.$$(`${panel} .dc-option`)).length===2);

  await page.click(`${panel} .dc-option[data-key="1"]`);
  await page.waitForTimeout(30);
  check('1번 클릭은 1번 선택 문구를 전달한다',sent[0]?.text==='첫 번째 안으로 진행한다',JSON.stringify(sent[0]));

  // 성공 후 재렌더를 기다리지 않고 새로 열어 직접 입력 흐름을 검증한다.
  await page.reload(); await page.click('#expBtn'); await page.waitForSelector(panel);
  await page.focus(panel); await page.keyboard.press('3');
  check('3번 키는 직접 입력칸을 연다',await page.isVisible(`${panel} .dc-custom`));
  await page.fill(`${panel} .dc-custom input`,'세 번째 방식으로 진행한다');
  await page.keyboard.press('Enter'); await page.waitForTimeout(30);
  check('직접 입력은 쓴 문구를 전달한다',sent[1]?.text==='세 번째 방식으로 진행한다',JSON.stringify(sent[1]));

  await page.reload(); await page.click('#expBtn'); await page.waitForSelector(panel);
  await page.focus(panel); await page.keyboard.press('Escape');
  check('Esc는 전송 없이 선택을 중단한다',(await page.textContent('#list .tabbody')).includes('선택을 중단했습니다.'));
  check('중단은 Slack에 아무것도 보내지 않는다',sent.length===2,String(sent.length));
  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail?1:0);
})();
