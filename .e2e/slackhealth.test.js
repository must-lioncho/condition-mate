// E2E for Slack 수집 데몬 자가 진단·자가 복구 — "사용자는 안 되는 것만 본다"를
// 없애기 위한 신뢰도 장치. Bound to REAL source on all three sides:
//   - Swift  : SlackHealth.swift를 그대로 컴파일해 실제 판정을 돌린다 (포팅 아님)
//   - daemon : slack-eyes-daemon.mjs에서 classifyFailure/setHealth를 떼어내 실행
//   - page   : SlackTranslateContent.swift에서 reflectHealth를 떼어내 DOM 스텁에 실행
// 핵심 계약:
//   - 앱이 스스로 고칠 수 있는 동안엔 사용자에게 아무것도 띄우지 않는다
//     (일시적 끊김·자동 재시작 = 조용한 '재연결 중', needsUser=false)
//   - 사용자만 풀 수 있는 상태에서만 안내를 띄운다 (네트워크 차단·토큰·복구 실패)
//   - 토큰 문제는 하트비트가 끊긴 뒤에도 재시작이 아니라 토큰 안내로 간다
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const PAGE = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/SlackTranslateContent.swift'), 'utf8');
const DAEMON = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs'), 'utf8');

let fails = 0;
const ok = (cond, msg) => { console.log((cond ? '  ok   ' : '  FAIL ') + msg); if (!cond) fails++; };

// 소스에서 함수 하나를 통째로 떼어낸다 (slackretrig.test.js와 같은 방식).
function fn(src, name, label) {
  let start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name + ' in ' + label);
  if (src.slice(start - 6, start) === 'async ') start -= 6;
  let paren = 0;
  let i = src.indexOf('(', start);
  for (; i < src.length; i++) {
    if (src[i] === '(') paren++;
    else if (src[i] === ')') { paren--; if (paren === 0) break; }
  }
  let depth = 0;
  for (let k = src.indexOf('{', i); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'slackhealth-'));

// ------------------------------------------------- 1. 데몬: 실패 원인 분류
{
  const health = { failures: 0, netError: '', authError: '', socket: 'starting' };
  const posted = [];
  const ctx = { health, postHealth: () => posted.push(JSON.parse(JSON.stringify(health))) };
  const body = fn(DAEMON, 'classifyFailure', 'daemon') + '\n' + fn(DAEMON, 'setHealth', 'daemon')
    + '\nreturn { classifyFailure, setHealth };';
  const { classifyFailure, setHealth } = new Function(...Object.keys(ctx), body)(...Object.values(ctx));

  classifyFailure(new Error('fetch failed'));
  ok(health.netError === 'fetch failed' && !health.authError,
    '슬랙에 못 닿음 → netError (네트워크·차단 안내로 간다)');
  classifyFailure(new Error('HTTP 403 — 슬랙 대신 JSON이 아닌 응답 (프록시·방화벽 차단으로 보임)'));
  ok(/403/.test(health.netError) && !health.authError,
    '프록시 차단 페이지(비-JSON 응답)도 네트워크 쪽으로 분류된다');
  classifyFailure(new Error('slack auth.test: invalid_auth'));
  ok(health.authError === 'invalid_auth',
    '토큰 거부 → authError (재시작이 아니라 토큰 안내로 간다)');
  classifyFailure(new Error('slack conversations.history: missing_scope'));
  ok(health.authError === 'missing_scope', '스코프 부족도 토큰 문제로 분류된다');

  posted.length = 0;
  setHealth({ socket: 'connected', failures: 0 });
  ok(posted.length === 1 && posted[0].socket === 'connected',
    '상태가 바뀌면 즉시 앱에 보고한다 (30초 주기와 별개로 전이는 바로)');
  setHealth({ socket: 'connected' });
  ok(posted.length === 1, '값이 그대로면 보고하지 않는다 (앱 엔드포인트 도배 방지)');

  // 소스 계약 — 붙는 순간 앱이 띄운 안내를 내릴 근거가 사라져야 한다.
  ok(/setHealth\(\{ socket: 'connected', failures: 0, netError: '', authError: '' \}\)/.test(DAEMON),
    '소켓이 붙으면 netError/authError를 지운다 (안내 자동 해제)');
  ok(/setInterval\(postHealth, 30_000\)/.test(DAEMON),
    '30초 주기 하트비트 (앱의 90초 판정 기준보다 촘촘)');
  ok(/health\.authError = '키체인에 토큰이 없습니다/.test(DAEMON),
    '토큰 없이 죽기 전에 원인을 남긴다 (exit 78 후에도 앱이 안내할 수 있게)');
}

// ------------------------------------------------- 2. Swift: 실제 상태 판정
// SlackHealth.swift를 그대로 컴파일해 돌린다 — 규칙을 테스트로 옮겨 적지 않는다.
const swiftc = '/Library/Developer/CommandLineTools/usr/bin/swiftc';
const sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk';
let probe = null;
if (fs.existsSync(swiftc) && fs.existsSync(sdk)) {
  const harness = path.join(tmp, 'main.swift');
  fs.writeFileSync(harness, `
import Foundation
// 시나리오 디렉터리를 데이터 루트로 삼고 실제 판정 결과를 그대로 찍는다.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
SlackTranslateStore.dir = root.appendingPathComponent("slack-translate")
print(SlackHealth.statusJSON())
`);
  try {
    execFileSync(swiftc, ['-sdk', sdk, '-module-cache-path', path.join(tmp, 'mc'),
      '-o', path.join(tmp, 'probe'),
      path.join(ROOT, 'Sources/Plugins/Slack/SlackHealth.swift'),
      path.join(ROOT, 'Sources/Plugins/Slack/SlackTranslateStore.swift'),
      harness], { stdio: ['ignore', 'ignore', 'pipe'] });
    probe = path.join(tmp, 'probe');
  } catch (e) {
    console.log('  SKIP  Swift 판정 (컴파일 실패)\n' + String(e.stderr || e).slice(0, 600));
  }
} else {
  console.log('  SKIP  Swift 판정 (swiftc 없음)');
}

// beat = health.json에 미리 심어둘 데몬의 마지막 보고. at은 "몇 초 전"으로 준다.
function judge(beat, { agoSec = 0, disabled = false } = {}) {
  const dir = fs.mkdtempSync(path.join(tmp, 'sc-'));
  fs.mkdirSync(path.join(dir, 'slack-translate'), { recursive: true });
  if (beat) {
    const b = Object.assign({}, beat, { at: Math.floor(Date.now() / 1000) - agoSec });
    fs.writeFileSync(path.join(dir, 'slack-translate', 'health.json'), JSON.stringify(b));
  }
  if (disabled) fs.writeFileSync(path.join(dir, 'slack-translate-disabled'), '');
  return JSON.parse(execFileSync(probe, [dir], { encoding: 'utf8' }));
}

if (probe) {
  let s = judge({ socket: 'connected' }, { agoSec: 5 });
  ok(s.state === 'ok' && s.needsUser === false, '소켓 연결됨 → 정상, 안내 없음');

  s = judge({ socket: 'connecting', failures: 1, netError: 'fetch failed' }, { agoSec: 5 });
  ok(s.state === 'connecting' && s.needsUser === false,
    '일시적 끊김(1회 실패)은 조용히 재시도 — 사용자에게 아무것도 띄우지 않는다');

  s = judge({ socket: 'connecting', failures: 4, netError: 'fetch failed' }, { agoSec: 5 });
  ok(s.state === 'blocked' && s.needsUser === true,
    '연속 실패 + 슬랙에 못 닿음 → 차단으로 확정하고 사용자에게 안내');
  ok(/VPN|네트워크/.test(s.advice), '차단 안내가 VPN·네트워크 조치를 알려준다: ' + s.advice.slice(0, 40) + '…');
  ok(/fetch failed/.test(s.detail), '무엇 때문인지(원인 문자열)를 함께 보여준다');

  s = judge({ socket: 'connecting', authError: 'invalid_auth', failures: 3 }, { agoSec: 5 });
  ok(s.state === 'auth' && s.needsUser === true, '토큰 거부 → 토큰 안내 (차단 안내가 아니라)');
  ok(/키체인/.test(s.advice) && /cm-slack-user-token/.test(s.advice),
    '토큰 안내가 어떤 키체인 항목을 갱신할지 알려준다');

  s = judge({ socket: 'connecting', authError: 'invalid_auth' }, { agoSec: 600 });
  ok(s.state === 'auth',
    '토큰 문제로 죽어 하트비트가 끊긴 뒤에도 재시작이 아니라 토큰 안내 (재시작으론 안 낫는다)');

  s = judge({ socket: 'connected' }, { agoSec: 600 });
  ok(s.state === 'restarting' && s.needsUser === false,
    '하트비트 90초 이상 끊김 → 앱이 조용히 자동 재시작 (사용자 안내 없음)');

  s = judge({ socket: 'connected' }, { agoSec: 60 });
  ok(s.state === 'ok', '60초 전 보고는 아직 살아있음 (30초 주기 × 2회까지 관용)');

  s = judge(null, {});
  ok(s.needsUser === false,
    '아직 한 번도 보고를 못 받은 초기 상태에서 겁주지 않는다: ' + s.state);

  s = judge({ socket: 'connected' }, { agoSec: 5, disabled: true });
  ok(s.state === 'off' && s.needsUser === false, '사용자가 끈 상태는 오류가 아니다');

  s = judge({ socket: 'connecting', netError: 'HTTP 403 "차단" \\ 페이지', failures: 3 }, { agoSec: 5 });
  ok(s.detail.includes('403'), '따옴표·역슬래시가 섞인 원인 문자열도 JSON이 깨지지 않는다');
}

// ------------------------------------------------- 3. 페이지: 무엇을 언제 보여주나
{
  const els = {};
  const mkEl = () => ({ style: {}, className: '', textContent: '', title: '', innerHTML: '' });
  // pChip/pChipT = reflectHealth가 함께 갱신하는 수집 경로 칩.
  for (const id of ['hChip', 'hChipT', 'hBanner', 'pChip', 'pChipT']) els[id] = mkEl();
  const ctx = {
    document: {
      getElementById: (id) => els[id],
      createElement: () => ({ set textContent(v) { this._t = v; }, get innerHTML() { return this._t || ''; } }),
    },
    localStorage: { getItem: () => null, setItem: () => {} },
    cache: null,
    hDetail: false,
    esc: (s) => String(s == null ? '' : s),
  };
  // 페이지 전역(cache/hDetail/hSig)을 매번 새로 세운 스코프에 심고 실제 함수를 돌린다.
  // syncErr/items = 리액션 동기화 실패 맵 — 연결 상태와 한 칩으로 합쳐졌으므로
  // 같은 함수가 둘 다 본다.
  // RT_EVENTS = 실시간 수신에 필요한 유저 이벤트 목록. 배너 안내가 이 배열을 그대로
  // 읽으므로 스텁에도 소스에서 떼어 심는다 (테스트에 목록을 다시 적지 않는다).
  const rtConst = (PAGE.match(/const RT_EVENTS = \[[^\]]*\];/) || [])[0];
  ok(!!rtConst, '페이지가 실시간 이벤트 목록을 상수 하나로 갖고 있다 (안내 문구마다 손으로 적지 않는다)');
  const run = (health, detail, extra) => {
    const b = 'let hSig="", hDetail=' + (detail ? 'true' : 'false')
      + ', cache=' + JSON.stringify(Object.assign({ health, items: [], syncErr: {} }, extra)) + ';\n'
      + 'let rsTimer = null, rsMsg = "";\n'   // 재연결 대기 타이머 (아래 3.6에서 따로 검증)
      + rtConst + '\n'
      + 'function syncHint(){ return "" }\n'
      + fn(PAGE, 'syncErrList', 'page') + '\n'
      + fn(PAGE, 'pathState', 'page') + '\n'
      + fn(PAGE, 'reflectPath', 'page') + '\n'
      + fn(PAGE, 'reflectHealth', 'page') + '\nreflectHealth();';
    new Function('document', 'localStorage', 'esc', b)(ctx.document, ctx.localStorage, ctx.esc);
  };

  run({ state: 'ok', title: '연결됨', detail: '슬랙 실시간 수신 중입니다.', advice: '', command: '', needsUser: false, ageSec: 3 });
  ok(els.hChip.className.includes('ok'), '정상일 때 칩은 정상 표시');
  ok(els.hChipT.textContent === '연결됨', '칩 문구 = 상태 제목');
  ok(els.hBanner.style.display === 'none', '정상일 때 배너 없음');

  run({ state: 'restarting', title: '재연결 중', detail: '데몬이 200초째 응답하지 않아…', advice: '', command: '', needsUser: false, ageSec: 200 });
  ok(els.hChip.className.includes('wait'), '자동 복구 중 = 대기색(보라) 칩');
  ok(els.hBanner.style.display === 'none',
    '자동 복구 중에는 배너를 띄우지 않는다 (앱이 고칠 수 있는 동안 사용자를 부르지 않음)');

  run({ state: 'blocked', title: '슬랙 접속 차단됨', detail: 'slack.com API에 닿지 못합니다 (fetch failed).',
        advice: 'VPN을 켜거나 네트워크를 바꾼 뒤 다시 연결을 눌러 주세요.',
        command: "curl -sS https://slack.com/api/api.test", needsUser: true, ageSec: 4 });
  ok(els.hChip.className.includes('warn'), '사용자 행동이 필요하면 주의색 칩');
  ok(els.hBanner.style.display === '', '이때만 배너를 띄운다');
  ok(/VPN/.test(els.hBanner.innerHTML), '배너에 실제 조치 안내가 들어간다');
  ok(/다시 연결/.test(els.hBanner.innerHTML), '배너에서 바로 다시 연결할 수 있다');
  ok(/api\.test/.test(els.hBanner.innerHTML), '손으로 확인할 명령도 함께 준다');

  // ---- 조치는 한 번에 하나만 ----
  // 토큰이 죽으면 데몬이 못 돌아 수집 경로도 같이 멈춘다. 그 경로 표시는 원인이
  // 아니라 결과인데, 여기에 '실시간 켜는 법'까지 붙으면 고칠 게 두 개(토큰이 또
  // 있는 줄)로 읽힌다 — 실제 사용자 오해(2026-08-11)라 계약으로 못 박는다.
  run({ state: 'auth', title: '슬랙 토큰 문제', detail: '슬랙이 토큰을 거부했습니다 (token_revoked).',
        advice: '슬랙 앱에서 토큰을 다시 발급한 뒤 키체인 항목을 갱신해 주세요.',
        command: 'security add-generic-password -U -s cm-slack-user-token -a slack -w',
        needsUser: true, ageSec: 5 });
  ok(!/Event Subscriptions|즉시 받으려면/.test(els.hBanner.innerHTML),
    '토큰 문제 중에는 실시간 수신(Event Subscriptions) 안내를 띄우지 않는다 — 조치가 둘로 보이면 안 된다');
  ok(/결과/.test(els.hBanner.innerHTML),
    '수집 경로가 멈춘 것은 토큰 문제의 결과임을 말해 준다 (별도 문제로 읽히지 않게)');
  ok(/openIntegrations\(true\)/.test(els.hBanner.innerHTML),
    '토큰 문제일 때 배너에서 바로 재발급 가이드를 열 수 있다');

  // 반대로 데몬이 멀쩡히 폴링만 돌고 있을 때는 실시간 켜는 법을 안내해야 한다.
  run({ state: 'ok', title: '연결됨', detail: '슬랙 실시간 수신 중입니다.', advice: '',
        command: '', needsUser: false, ageSec: 3, realtimeAt: 0, pollAt: 1750000000, pollConvs: 12 },
      true);
  ok(/폴링 수집/.test(els.hBanner.innerHTML), '실시간 이벤트가 없으면 폴링으로 돌고 있다고 말한다');
  ok(/message\.channels/.test(els.hBanner.innerHTML),
    '이때만 실시간 켜는 법(이벤트 목록)을 안내한다');

  // ---- 연결 + 동기화 = 하나의 상태 표시 ----
  const okH = { state: 'ok', title: '연결됨', detail: '슬랙 실시간 수신 중입니다.',
                advice: '', command: '', needsUser: false, ageSec: 3 };
  const errs = { syncErr: { 'C1:1': { error: 'missing_scope', action: 'reaction.remove', at: 1 } },
                 items: [{ id: 'C1:1', channelName: 'general', textKo: '안녕' }] };

  run(okH, false, errs);
  ok(els.hChip.className.includes('warn'),
    '연결은 정상이어도 동기화 실패가 남아 있으면 상태 칩이 주의색 하나로 합쳐진다');
  ok(/연결 및 동기화 실패/.test(els.hChipT.textContent),
    '칩 문구가 연결·동기화를 하나로 말한다: ' + els.hChipT.textContent);
  ok(els.hBanner.style.display === '' && /missing_scope/.test(els.hBanner.innerHTML),
    '칩을 누르지 않아도(실패 상태) 배너에 실제 에러 내용이 나온다');
  ok(/동기화 재시도/.test(els.hBanner.innerHTML), '배너에서 바로 재시도할 수 있다');

  run(okH, false);
  ok(!els.hChip.className.includes('warn') && els.hChipT.textContent === '연결됨',
    '동기화 실패가 해결되면 경고는 사라지고 평상 상태로 돌아간다');
  ok(els.hBanner.style.display === 'none',
    '정상 상태에서 칩을 눌러 열지 않는 한 에러 문구가 남지 않는다');
  ok(!/syncWarn/.test(PAGE), '별도 동기화 실패 칩은 없다 (상태 표시는 하나)');

  ok(/hchip.*wait|\.hchip\.wait/.test(PAGE), '대기 상태 전용 스타일이 있다');
  ok(!/#(7bd88f|2ecc71|00ff00)/i.test(PAGE.split('.hchip')[1] || ''),
    '상태 칩에 신호등 녹색을 쓰지 않는다 (프로젝트 색 규칙)');
  ok(/fetch\('\/api\/slack\/daemon\/restart'/.test(PAGE), '다시 연결이 재시작 엔드포인트를 호출한다');
}

// ------------------------------------------------- 3.4 '다시 연결' 진행 표시
// 눌러도 화면이 그대로면 사용자는 눌렸는지부터 의심한다 (실제 지적, 2026-08-11).
// 누른 순간부터 초가 올라가고, 붙는 순간 "몇 초 걸렸다"로 끝나야 한다.
{
  const els = { hSt: { textContent: '' }, intSt: { textContent: '' } };
  // rsAt을 과거로 심어 "N초째"를 그 자리에서 만든다 (실제로 기다리지 않는다).
  const paint = (agoSec, state, fail) => {
    const b = 'let rsAt = Date.now() - ' + (agoSec * 1000) + ', rsEnd = 0, rsMsg = "", rsTimer = 1'
      + ', rsFail = ' + JSON.stringify(fail || '')
      + ', cache = ' + JSON.stringify({ health: { state } }) + ';\n'
      + 'const RS_GIVEUP = ' + (PAGE.match(/const RS_GIVEUP = (\d+)/) || [])[1] + ';\n'
      + 'function reflectHealth(){}\n'
      + fn(PAGE, 'paintRestart', 'page') + '\npaintRestart(); return { rsMsg, rsTimer, rsEnd };';
    const out = new Function('document', 'clearInterval', b)(
      { getElementById: (id) => els[id] }, () => {});
    return { msg: els.hSt.textContent, modal: els.intSt.textContent, state: out };
  };

  let r = paint(3, 'auth');
  ok(/3초째/.test(r.msg), '누른 뒤 몇 초가 지났는지 계속 보여준다: ' + r.msg);
  ok(/기다리는 중/.test(r.msg), '무엇을 기다리는 중인지 말해 준다 (눌리긴 했다는 신호)');
  ok(r.modal === r.msg, '배너에서 눌렀든 연동 모달에서 눌렀든 같은 문구를 본다');

  r = paint(12, 'ok');
  ok(/연결됐습니다/.test(r.msg) && /12초/.test(r.msg),
    '실제로 붙는 순간 몇 초 걸렸는지로 끝난다: ' + r.msg);
  ok(r.state.rsEnd > 0, '성공 문구는 잠깐 남았다가 저절로 사라진다');

  r = paint(95, 'auth');
  ok(/붙지 않습니다/.test(r.msg) && /95초/.test(r.msg),
    '오래 지나도 안 붙으면 무한히 세지 않고 원인이 남았다고 말한다: ' + r.msg);

  r = paint(2, 'auth', '재시작 실패 — 아래 명령을 직접 실행해 주세요');
  ok(/재시작 실패/.test(r.msg), '요청 자체가 실패하면 초 세기 대신 실패를 말한다');

  ok(/rsTimer\?'disabled':''/.test(PAGE) || /rsTimer\s*\?\s*'disabled'/.test(PAGE),
    '기다리는 동안 다시 연결 버튼은 잠긴다 (연타로 카운터가 초기화되지 않게)');
  ok(/!bad && !hDetail && !rsTimer/.test(PAGE),
    '기다리는 동안에는 배너를 붙잡아 둔다 (붙자마자 사라지면 결과를 못 본다)');
}

// ------------------------------------------------- 3.5 재발급 가이드
// 조치의 대부분이 앱 밖(슬랙 웹 설정)이라, "토큰을 다시 발급하세요" 한 줄만 주면
// 사용자가 메뉴를 검색해야 한다. 가이드는 앱만 보고 끝낼 수 있어야 하므로
// 메뉴 경로·버튼 이름·순서가 실제로 들어 있는지, 스코프 목록이 Swift 원본에서
// 오는지를 계약으로 확인한다.
{
  const INTG = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/SlackIntegrations.swift'), 'utf8');
  // 스코프 목록의 원본은 이제 연동 카탈로그(IntegrationCatalog.slackUserScopes)이고,
  // SlackIntegrations는 그것을 requiredUserScopes로 되비쳐 응답에 싣는다. 계약은
  // 그대로다 — 페이지가 목록을 따로 적지 않고 응답에서 받아 그린다.
  ok(/userScopes\\":\[\\\(requiredUserScopes/.test(INTG),
    '검사 응답이 필요한 스코프 목록을 그대로 내려준다 (가이드가 목록을 따로 적지 않게)');
  ok(/requiredUserScopes: \[String\] \{ IntegrationCatalog\.slackUserScopes \}/.test(INTG),
    '스코프 목록의 원본은 연동 카탈로그 한곳이다 (슬랙 쪽에 사본을 두지 않는다)');

  const body = (PAGE.match(/const RT_EVENTS = \[[^\]]*\];/) || [''])[0] + '\n'
    + (PAGE.match(/const FALLBACK_SCOPES = \[[\s\S]*?\];/) || [''])[0] + '\n'
    + 'let intGuide = true, intData = ' + JSON.stringify({
        checks: { slackUser: { state: 'fail', error: 'token_revoked', account: 'must' } },
        userScopes: ['reactions:read', 'chat:write'],
      }) + ';\n'
    + fn(PAGE, 'intSlackBad', 'page') + '\n'
    + fn(PAGE, 'intGuideHTML', 'page') + '\nreturn intGuideHTML();';
  const html = new Function(body)();

  for (const [needle, what] of [
    ['api.slack.com/apps', '슬랙 앱 설정으로 가는 링크'],
    ['Socket Mode', 'Socket Mode 확인 단계'],
    ['Event Subscriptions', '실시간 이벤트 구독 단계'],
    ['Subscribe to events on behalf of users', '유저 이벤트 섹션 이름 (봇 이벤트와 헷갈리지 않게)'],
    ['message.mpim', '추가할 이벤트 4개'],
    ['User Token Scopes', '유저 토큰 스코프 위치'],
    ['Reinstall to Workspace', '재설치 버튼 이름'],
    ['User OAuth Token', 'xoxp 토큰을 어디서 복사하는지'],
    ['App-Level Tokens', 'xapp 토큰 발급 위치'],
    ['connections:write', 'xapp 토큰에 필요한 스코프'],
    ['cm-slack-user-token', '키체인 갱신 명령 (사용자 토큰)'],
    ['cm-slack-app-token', '키체인 갱신 명령 (앱 토큰)'],
    ['reactions:read', '스코프 목록 — 서버가 내려준 값으로 그린다'],
  ]) ok(html.includes(needle), '가이드에 ' + what + '이(가) 있다');

  ok(!html.includes('reactions:write'),
    '스코프 목록은 서버 응답 그대로다 (페이지 폴백 목록이 섞이지 않는다)');
  ok(/Bot Token Scopes가 아닙니다|bot events가 아닙니다/.test(html),
    '헷갈리기 쉬운 봇용 설정과 구분해 준다');
  ok(/재설치로 갱신되지 않습니다/.test(html),
    'xapp 토큰이 재설치와 무관한 별도 토큰임을 알려준다');
  // 계정명을 'slack'으로 굳히면 계정이 다른 사용자는 같은 서비스에 항목이 둘 생겨
  // "갱신했는데 그대로"가 된다 — 실제 등록된 계정을 그대로 써야 한다.
  ok(/-s cm-slack-user-token -a must -w/.test(html),
    '키체인 명령이 이미 등록된 계정명을 그대로 쓴다 (중복 항목이 생기지 않게)');
  ok(/-s cm-slack-app-token -a slack -w/.test(html),
    '검사 결과가 없는 항목은 기본 계정명으로 안내한다');

  // 자동 펼침 — 실제로 슬랙 토큰이 문제일 때만. 정상인데 펼쳐 두면 소음이 된다.
  const openWhen = (checks) => new Function(
    'let intGuide = null, intData = ' + JSON.stringify({ checks }) + ';\n'
    + fn(PAGE, 'intSlackBad', 'page') + '\nreturn intSlackBad();')();
  ok(openWhen({ slackUser: { state: 'fail' }, slackApp: { state: 'ok' } }) === true,
    '토큰이 거부되면 가이드가 저절로 펼쳐진다');
  ok(openWhen({ slackUser: { state: 'ok', missingScopes: ['chat:write'] } }) === true,
    '토큰은 살아 있어도 스코프가 빠졌으면 펼쳐진다 (조용히 실패하는 상태)');
  ok(openWhen({ slackUser: { state: 'ok' }, slackApp: { state: 'ok' } }) === false,
    '둘 다 정상이면 접어 둔다');
}

// ------------------------------------------------- 4. 앱 배선
{
  const APP = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/AppDelegate.swift'), 'utf8');
  const REG = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Core/WorkerRegistry.swift'), 'utf8');
  const STORE = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/SlackTranslateStore.swift'), 'utf8');
  ok(/case "\/api\/slack\/health":/.test(APP), '앱이 데몬 하트비트를 받는다');
  ok(/case "\/api\/slack\/daemon\/restart":/.test(APP), '앱이 재시작 요청을 받는다');
  ok(/SlackHealth\.watchdogTick\(\)/.test(APP) && /tick % 30 == 0/.test(APP),
    '워치독이 30초마다 돈다 (하트비트 90초 판정과 맞물림)');
  ok(/DispatchQueue\.global\(qos: \.utility\)\.async \{ SlackHealth\.watchdogTick\(\) \}/.test(APP),
    '워치독은 메인 스레드 밖에서 — launchctl 실행이 UI를 멈추면 안 된다');
  ok(/SlackHealth\.onEvent = \{/.test(APP), '복구 이벤트가 워커 상태 행·로그로 간다');
  ok(/"slack-eyes"\)\s*$/m.test(REG) || /w\.id == "slack-eyes"/.test(REG),
    '시스템 페이지에서 이 데몬을 켜고/끄고 되살릴 수 있다');
  ok(/restartable/.test(REG) && /w\.restartable/.test(APP), '워커 행에 다시 연결 버튼이 붙는다');
  ok(STORE.includes('\\"health\\":\\(SlackHealth.statusJSON())'),
    '상태가 기존 5초 피드에 실려 온다 (새 폴링 추가 없음)');
  // 실패 맵 자가 검증 — 밖에서 원인이 풀리면(스코프 부여·네트워크 복구·항목 삭제)
  // 사용자가 아무것도 안 해도 경고가 사라져야 한다.
  ok(/func revalidateSyncErrors\(\)/.test(STORE) && /revalidateSyncErrors\(\)/.test(STORE.split('func revalidateSyncErrors')[0]),
    '피드를 읽을 때 실패 맵을 다시 검증한다');
  ok(/timeIntervalSince\(lastReval\) >= 60/.test(STORE), '재검증은 60초에 한 번으로 제한');
  ok(/guard lookup\(id: id\) != nil else \{[\s\S]{0,120}ok: true/.test(STORE),
    '항목이 사라진 실패는 즉시 정리한다');
}

// ------------------------------------------------- 5. 수집 경로 칩의 자리 = 디버그 패널 안
// 툴바에는 '연결됨' 하나만 둔다. 경로 칩(실시간 수신/폴링 수집)까지 밖에 서 있으면
// 상태가 두 개인 것처럼 읽혀 혼동을 준다 — 지금 어느 경로인지는 디버그를 켠 사람만
// 궁금하다. 그래서 칩은 디버그 패널 최상단에 있고, 로그를 다시 그려도 살아남아야 한다.
{
  const panel = PAGE.slice(PAGE.indexOf('<div class="dbgpanel" id="dbgPanel"'),
    PAGE.indexOf('<div id="list">'));
  const toolbar = PAGE.slice(PAGE.indexOf('<div class="toolbar">'), PAGE.indexOf('<div class="hbanner"'));
  ok(/id="pChip"/.test(panel), '수집 경로 칩이 디버그 패널 안에 있다');
  ok(!/id="pChip"/.test(toolbar), '툴바 밖으로는 나오지 않는다 (연결됨 칩만 남는다)');
  ok(/id="hChip"/.test(toolbar), "'연결됨' 칩은 툴바에 그대로 둔다");
  ok(panel.indexOf('id="pChip"') < panel.indexOf('id="dbgBody"'), '패널 최상단 — 액션 로그보다 위');
  const rd = fn(PAGE, 'renderDbgPanel', 'page');
  ok(/body\.innerHTML =/.test(rd) && !/panel\.innerHTML =/.test(rd),
    '로그는 body만 다시 쓴다 — 패널을 통째로 덮으면 칩이 사라진다');
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
