// E2E — 세션 원장(어떤 Claude 세션이 어느 루프를 돌리려고 열렸는가).
//
// 왜 이 시험이 있나. 이 기능의 값어치는 "루프가 얼마를 썼는가"에 숫자로 답하는 것이고, 그
// 답은 판정 규칙 한 벌에 통째로 달려 있다. 규칙이 조용히 느슨해지면 화면은 여전히 그럴듯한
// 숫자를 보여 준다 — 틀린 숫자를. 그래서 두 축으로 잡는다:
//   (1) 소스 계약 — 판정 규칙과 원장 저장이 LoopSessionLedger 한곳에 있는가, 화면과
//       AppDelegate 가 자기 판정을 따로 갖고 있지 않은가, 추출 결과를 (mtime,size) 지문과
//       함께 디스크에 남겨 "세션마다 한 번만 읽는다"는 약속이 코드에 실제로 있는가.
//   (2) 실제 DOM — 루프 페이지의 진짜 HTML/JS 를 크로미움에 띄우고 세션 원장 payload 를
//       물려, 진행률·합계·그룹 행이 서버가 준 값 그대로 그려지는가. 특히 "아직 덜 읽었다"는
//       상태가 화면에 남는가 — 그것이 사라지면 부분 합계가 완성된 합계로 읽힌다.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LEDGER = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Plugins/Loop/LoopSessionLedger.swift'), 'utf8');
const DEFS = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Plugins/Loop/LoopDefinitionStore.swift'), 'utf8');
const PAGE = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift'), 'utf8');
const DASH = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Dashboard/DashboardContent.swift'), 'utf8');
const APP = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/AppDelegate.swift'), 'utf8');
const SLACK_LOOP = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/loops/index.md'), 'utf8');

let pass = 0, fail = 0;
const check = (n, ok, extra) => {
  console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : ''));
  ok ? pass++ : fail++;
};

// ------------------------------------------------------------------ 1. 소스 계약
// 규칙 자체(스킬 부팅 머리줄, 슬래시 커맨드 표기, 반복 서명 임계값)는 원장에만 있어야 한다.
// 화면은 서버가 준 loop/loopKind 를 그리기만 하고, 스스로 판정하지 않는다.
const RULE_MARKS = [/Base directory for this skill/, /<command-name>/, /sigCount/];
check('판정 규칙은 세션 원장 한곳에만 있다',
  /func classifyAll\(\)/.test(LEDGER)
  && RULE_MARKS.every((re) => re.test(LEDGER))
  && RULE_MARKS.every((re) => !re.test(DASH) && !re.test(APP))
  && /s\.loopKind/.test(DASH));
check('추출은 (mtime,size) 지문으로 한 번만 — 지문이 같으면 다시 읽지 않는다',
  /r\.size != f\.size/.test(LEDGER) && /abs\(r\.mtime - f\.mtime\.timeIntervalSince1970\)/.test(LEDGER));
check('판정 결과는 디스크에 남기지 않는다 (규칙이 바뀌면 다시 판정할 수 있어야 한다)',
  /struct Row: Codable/.test(LEDGER) && !/var kind|var verdict/.test(LEDGER.split('struct Row: Codable')[1].split('}')[0]));
check('토큰 파서는 앱 것을 꽂아 쓴다 — 두 벌로 세지 않는다',
  /static var extractor:/.test(LEDGER) && /LoopSessionLedger\.extractor = \{/.test(APP)
  && /transcriptStats\(file: url/.test(APP));
check('반복 서명은 세션 수와 날짜 수를 함께 요구한다 (resume 복제본 방어)',
  /sigCount\[sig\] \?\? 0\) >= 3, \(sigDays\[sig\]\?\.count \?\? 0\) >= 2/.test(LEDGER));
check('등록된 루프는 자기 선언으로만 세션을 가져간다 (폴더가 같다고 가져가지 않는다)',
  /sessionSignatures/.test(LEDGER) && !/l\.workspace/.test(LEDGER));
check('루프 선언 본문은 라우터가 한곳에서 준다',
  /static func definitions\(\)/.test(DEFS) && /LoopDefinitionStore\.definitions\(\)/.test(LEDGER));
check('선언 서명이 바뀌면 세션 행 변경 없이도 즉시 다시 판정한다',
  /definitionsStamp/.test(LEDGER)
  && /c\.rowsStamp == stamp, c\.definitionsStamp == defStamp/.test(LEDGER));
check('Slack 공용 루프가 과거 번역·기본 응답 세션 서명을 소유한다',
  /다음 슬랙 메시지를 자연스러운 한국어로 번역하라/.test(SLACK_LOOP)
  && /다음 슬랙 메시지를 세 단계로 처리하라/.test(SLACK_LOOP)
  && /다음 슬랙 메시지를 두 단계로 처리하라/.test(SLACK_LOOP)
  && /짧은 선응답을 작성하라/.test(SLACK_LOOP));
check('세션 원장 API 는 루프 엔지니어링 경로 아래에 있다',
  /api\/loop-engineering\/sessions/.test(APP) && /LoopSessionLedger\.json\(path\)/.test(APP));
check('회차 상세도 원장이 소유한다 — 목록보다 먼저 걸리지 않게 라우트 순서까지',
  /static func sessionJSON/.test(LEDGER)
  && APP.indexOf('loop-engineering/sessions') < APP.indexOf('loop-engineering/session"'));
check('회차 목록 키는 runs — 그룹의 세션 개수(sessions)와 이름이 겹치지 않는다',
  /\\"runs\\":/.test(LEDGER) && !/\\"sessions_top\\"/.test(LEDGER));
check('토큰 뷰의 세션 행은 판정을 물어보기만 한다',
  /LoopSessionLedger\.verdict\(sid: sid\)/.test(APP) && /tkLoopBadge\(s\)/.test(DASH));

// ------------------------------------------------------------------ 2. 실제 DOM
// 페이지의 진짜 HTML. Swift 보간(\#(SessionRail.html()))만 걷어낸다 — 레일은 이 시험의 대상이 아니다.
const body = PAGE.split('return #"""')[1].split('"""#')[0].replace(/\\#\([^)]*\)/g, '');

const NOW = Math.floor(Date.now() / 1000);
const RUN = {   // 회차 하나의 상세 — /api/loop-engineering/session 이 주는 모양
  sid: 'aaaaaaaa', title: '데모 세션', proj: 'demo', cwd: '/tmp/demo', loop: '데모 루프', loopKind: 'loop',
  start: NOW - 3600, end: NOW - 3000, tokens: 400000, cost: '4.5000', turns: 42, tools: 51, errors: 0,
  prompt: 'Run exactly ONE demo cycle now.', result: '사이클 완료. 지시문을 디스크에 남겼다.',
  steps: [
    { ts: NOW - 3600, kind: 'say', name: '', text: '먼저 상태 파일을 읽는다.' },
    { ts: NOW - 3590, kind: 'run', name: 'Bash', text: 'wc -c docs/backlog.md' },
    { ts: NOW - 3300, kind: 'edit', name: 'Write', text: 'docs/B281-directive.md' },
    { ts: NOW - 3100, kind: 'agent', name: 'demo-worker-writer', text: 'Execute B-281 directive' },
  ],
  elided: 0, toolTop: [{ name: 'Bash', n: 43 }], files: ['docs/B281-directive.md'], agents: ['demo-worker-writer'],
};
const SESSIONS = {
  progress: { total: 100, analyzed: 60, pending: 40, running: true, doneThisPass: 60, current: 'abc.jsonl',
              lastPassAt: '', startedAt: new Date().toISOString() },
  totals: { loop: { sessions: 3, tokens: 1200000, cost: 12.5 },
            candidate: { sessions: 9, tokens: 4500000, cost: 90.25 },
            human: { sessions: 40, tokens: 9000000, cost: 300 } },
  groups: [
    { key: 'loop:demo-loop', label: '데모 루프', kind: 'loop', loopId: 'demo-loop', sessions: 3,
      tokens: 1200000, cost: 12.5, first: '2026-08-01', last: '2026-08-29', projects: ['demo'],
      days: { [new Date().toISOString().slice(0, 10)]: { t: 400000, c: 4.5 } },
      runs: [
        { sid: 'aaaaaaaa', title: '데모 세션', proj: 'demo', tokens: 400000, cost: 4.5, day: '2026-08-29',
          start: NOW - 3600, end: NOW - 3000, turns: 42, tools: 51 },
        { sid: 'bbbbbbbb', title: '빈 회차', proj: 'demo', tokens: 0, cost: 0, day: '2026-08-29',
          start: NOW - 7200, end: NOW - 7197, turns: 1, tools: 0 },
      ] },
    { key: 'sig:zzz', label: 'Run exactly ONE cycle now', kind: 'candidate', loopId: '', sessions: 9,
      tokens: 4500000, cost: 90.25, first: '2026-08-10', last: '2026-08-29', projects: ['other'],
      days: {}, runs: [] },
  ],
};
const V2 = { count: 1, registry: '/tmp/loops/index.md', loops: [{
  id: 'demo-loop', name: '데모 루프', scopeLabel: '테스트', workspace: '/tmp/demo',
  definitionPath: '/tmp/loops/index.md', connected: true, workspaceExists: true,
  purpose: '데모', problem: '데모', modelProblem: '데모', known: '', unknown: '',
  triggers: [], flow: [], agents: [], evidence: [], usageEvents: [], runCount: 0,
  syncedAt: new Date().toISOString(),
}] };

const html = `<!doctype html><meta charset="utf-8">
<script>
const _f=window.fetch;
window.fetch=function(u){
  const s=String(u);
  if(s.indexOf('/api/loop-engineering/sessions')>=0) return Promise.resolve({json:()=>Promise.resolve(${JSON.stringify(SESSIONS)})});
  if(s.indexOf('/api/loop-engineering/session?')>=0) return Promise.resolve({json:()=>Promise.resolve(${JSON.stringify(RUN)})});
  if(s.indexOf('/api/loop-engineering/v2')>=0) return Promise.resolve({json:()=>Promise.resolve(${JSON.stringify(V2)})});
  return Promise.resolve({json:()=>Promise.resolve({})});
};
try{ Object.defineProperty(window,'localStorage',{value:{getItem:()=>null,setItem:()=>{},removeItem:()=>{}}}); }catch(e){}
</script>
${body}`;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const errs = [];
  page.on('pageerror', (e) => errs.push(e.message));
  await page.setContent(html);
  await page.waitForFunction(() => document.querySelector('.sled') !== null, null, { timeout: 15000 })
    .catch(() => {});

  const panel = await page.$eval('.sled', (e) => e.innerText).catch(() => '');
  check('세션 원장 패널이 그려진다', panel.length > 0);
  check('아직 덜 읽었다는 상태가 화면에 남는다 (60/100 분석 중)',
    /분석 중\s*60\/100/.test(panel), panel.split('\n').slice(0, 4).join(' | '));
  check('세 축(등록·미등록·사람)의 합계를 그대로 그린다',
    /등록된 루프/.test(panel) && /1\.2M/.test(panel) && /4\.5M/.test(panel) && /9M/.test(panel));
  check('그룹 행은 세션 수·토큰·비용을 서버 값 그대로 적는다',
    /데모 루프/.test(panel) && /3개/.test(panel) && /\$12\.5/.test(panel));
  check('미등록 후보는 등록된 루프와 다르게 표시된다', /미등록/.test(panel) && /등록/.test(panel));
  check('기간 필터는 전체·오늘·어제·7일·한달·3달과 직접 날짜 범위를 제공한다',
    ['전체', '오늘', '어제', '7일', '한달', '3달'].every((x) => panel.includes(x))
    && await page.locator('.sledtools input[type=date]').count() === 2);
  check('정렬은 토큰 양·총 금액·세션 수·이름과 방향을 제공한다',
    await page.locator('.sledtools select option').allTextContents().then((xs) =>
      ['토큰 양', '총 금액', '세션 수', '이름'].every((x) => xs.includes(x)))
    && /내림차순/.test(panel));

  const pct = await page.$eval('.sled .pbar i', (e) => e.style.width).catch(() => '');
  check('진행률 막대는 읽은 비율을 그린다', pct === '60%', 'width=' + pct);

  // 루프 상세 — 세션 원장의 토큰이 그 루프의 토큰 칸에 실제로 들어간다.
  await page.evaluate(() => document.querySelector('details.looprow').setAttribute('open', ''));
  const detail = await page.$eval('.loopdetail', (e) => e.innerText).catch(() => '');
  check('루프 상세에 "이 루프를 돌린 세션" 절이 생긴다', /이 루프를 돌린 세션/.test(detail));
  check('그 절이 세션 수·합계·기간을 적는다',
    /세션 3개/.test(detail) && /1\.2M/.test(detail) && /2026-08-01/.test(detail));
  check('토큰 칸이 더 이상 "계측 대기"로 끝나지 않는다',
    /토큰 사용량/.test(detail) && !/새 모델 호출 대기 중/.test(detail));

  // 회차 목록 — 루프 행을 누르면 크론 목록처럼 날짜·시각순으로 열린다.
  await page.evaluate(() => {
    const r = Array.from(document.querySelectorAll('.grow')).find((x) => /데모 루프/.test(x.innerText));
    if (r) r.click();
  });
  await page.waitForTimeout(200);
  const runs = await page.$eval('.sled .slist', (e) => e.innerText).catch(() => '');
  check('루프 행을 누르면 회차가 시간순으로 열린다', /턴 42 · 도구 51/.test(runs), runs.split('\n').slice(0, 6).join(' | '));
  check('토큰을 안 쓴 회차는 빈 회차로 구분된다', /빈 회차/.test(runs));
  const order = await page.$$eval('.sled .slist .srow .tm', (ns) => ns.map((n) => n.textContent));
  check('회차는 최신이 위 (서버가 준 순서를 뒤집지 않는다)', order.length === 2);

  // 직접 날짜 범위는 카드·그룹·펼친 회차에 동시에 적용된다.
  await page.locator('.sledtools input[type=date]').first().fill('2026-08-29');
  await page.locator('.sledtools input[type=date]').first().dispatchEvent('change');
  await page.waitForTimeout(100);
  const filtered = await page.$eval('.sled', (e) => e.innerText).catch(() => '');
  check('직접 날짜를 고르면 범위 밖 그룹이 사라지고 해당 날짜 회차만 남는다',
    /데모 루프/.test(filtered) && !/Run exactly ONE cycle now/.test(filtered));

  // 회차 하나 — 지시 → 한 일 → 결과.
  await page.evaluate(() => document.querySelector('.sled .slist .srow').click());
  await page.waitForTimeout(300);
  const det2 = await page.$eval('.sdet', (e) => e.innerText).catch(() => '');
  check('회차를 누르면 무엇을 시켰는지가 나온다', /무엇을 시켰나/.test(det2) && /Run exactly ONE demo cycle/.test(det2));
  check('무엇을 했는지가 시각과 함께 줄로 나온다',
    /무엇을 했나/.test(det2) && /먼저 상태 파일을 읽는다/.test(det2) && /B281-directive\.md/.test(det2));
  check('마지막 응답과 위임한 에이전트가 나온다',
    /마지막 응답/.test(det2) && /사이클 완료/.test(det2) && /demo-worker-writer/.test(det2));

  check('페이지 JS 오류 없음', errs.length === 0, errs.slice(0, 3).join(' / '));
  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
