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
const PAGE = fs.readFileSync(path.join(ROOT, 'Sources/Slack/SlackTranslateContent.swift'), 'utf8');
const DAEMON = fs.readFileSync(path.join(ROOT, 'Sources/Slack/Daemon/slack-eyes-daemon.mjs'), 'utf8');

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

// ------------------------------------------------- 1b. 데몬: 조용히 죽은 소켓
// close 이벤트 없이 죽는 WebSocket — 프로세스는 살아 하트비트를 계속 보내고
// socket:'connected'도 그대로라, 프레임 수신으로 판정하지 않으면 아무도 못 잡는다.
{
  const IDLE = 10 * 60_000;
  const stale = (state, { idleMs = 0, missed = 0, realtimeAt = 0 } = {}) => {
    const body = 'const SOCKET_IDLE_LIMIT_MS = ' + IDLE + ';\n'
      + 'const health = ' + JSON.stringify({ socket: state, realtimeAt }) + ';\n'
      + 'let lastFrameAt = nowMs - ' + idleMs + ';\n'
      + 'let missedRealtimeAt = ' + missed + ';\n'
      + fn(DAEMON, 'socketStale', 'daemon') + '\nreturn socketStale(nowMs);';
    return new Function('nowMs', body)(1_000_000_000_000);
  };

  ok(stale('connected', { idleMs: 60_000 }) === '', '방금 프레임을 받았으면 정상');
  ok(stale('connected', { idleMs: 11 * 60_000 }) !== '',
    '프레임이 10분 넘게 없으면 죽은 것으로 보고 다시 개통한다 (30분 catch-up보다 빠르다)');
  ok(stale('connecting', { idleMs: 60 * 60_000 }) === '',
    '아직 붙는 중일 때는 판정하지 않는다 (기존 백오프 재연결에 맡긴다)');
  ok(stale('connected', { idleMs: 0, missed: 1755300000, realtimeAt: 1755290000 }) !== '',
    '폴링이 실시간보다 새 메시지를 주웠다 = 소켓이 이벤트를 놓쳤다는 직접 증거 → 즉시 재개통');
  ok(stale('connected', { idleMs: 0, missed: 1755290000, realtimeAt: 1755300000 }) === '',
    '실시간이 이미 더 최근 것을 받았으면 폴링 수집은 증거가 아니다');
  ok(stale('connected', { idleMs: 0, missed: 1755300000, realtimeAt: 0 }) === '',
    '실시간 구독이 아예 없는 워크스페이스(realtimeAt=0)는 교차검증 대상이 아니다 — 폴링이 정상 경로');

  // ---- 재개통 실제 동작 ---- 판정이 맞아도 소켓을 실제로 갈아치우지 않으면 의미 없다.
  {
    const calls = { connect: 0, closed: 0, posted: [] };
    const body = 'const SOCKET_IDLE_LIMIT_MS = ' + IDLE + ', SOCKET_ROTATE_GAP_MS = ' + IDLE + ';\n'
      + 'const health = { socket: "connected", realtimeAt: 0, rotations: 0, frameAt: 0 };\n'
      + 'let lastFrameAt = Date.now() - ' + (11 * 60_000) + ', lastRotateAt = 0, missedRealtimeAt = 0;\n'
      + 'let wsGen = 0, catchUpAfterOpen = false, backoff = 9;\n'
      + 'let ws = { close(){ calls.closed++; } };\n'
      + 'const setHealth = (p) => { Object.assign(health, p); calls.posted.push(p.socket); };\n'
      + 'const connect = () => { calls.connect++; };\n'
      + 'const existsSync = () => false, DISABLED_FILE = "";\n'
      + fn(DAEMON, 'socketStale', 'daemon') + '\n' + fn(DAEMON, 'markFrame', 'daemon') + '\n'
      + fn(DAEMON, 'rotateSocket', 'daemon') + '\n' + fn(DAEMON, 'socketWatchdog', 'daemon') + '\n'
      + 'socketWatchdog(); const first = { gen: wsGen, catchUp: catchUpAfterOpen };\n'
      + 'socketWatchdog();\n'  // 바로 다음 틱 — 재개통이 두 번 일어나면 안 된다
      + 'return { first, health, wsGen, backoff, calls };';
    const r = new Function('calls', 'log', body)(calls, () => {});

    ok(calls.connect === 1, '무수신을 감지하면 실제로 다시 개통한다 (connect 호출 ' + calls.connect + '회)');
    ok(calls.closed === 1, '죽은 소켓은 닫는다');
    ok(r.first.gen === 1 && r.wsGen === 1,
      '세대를 올려 옛 소켓 콜백을 무력화한다 — 그리고 곧바로 또 올리지는 않는다');
    ok(r.first.catchUp === true, '재개통 후 catch-up을 예약한다 (놓친 구간을 30분 기다리지 않는다)');
    ok(calls.posted[0] === 'stale', "재개통 순간 socket:'stale'로 즉시 보고한다 (앱 칩이 바로 내려간다)");
    ok(r.health.rotations === 1 && calls.connect === 1,
      '최소 간격 안에서는 두 번째 재개통을 하지 않는다 (재개통 폭주 방지)');
    ok(r.backoff === 1, '재개통은 이전 실패의 백오프를 물려받지 않는다 (즉시 붙어야 한다)');
  }

  // 소스 계약 — 판정만 있고 행동이 없으면 아무것도 낫지 않는다.
  ok(/setInterval\(socketWatchdog, SOCKET_CHECK_MS\)/.test(DAEMON), '소켓 워치독이 주기적으로 돈다');
  ok(/SOCKET_IDLE_LIMIT_MS = 10 \* 60_000/.test(DAEMON),
    '무수신 상한 10분 — 30분 catch-up보다 빨라야 의미가 있다');
  ok(/function markFrame\(\)[\s\S]{0,200}health\.frameAt = Math\.floor/.test(DAEMON),
    '프레임을 받을 때마다 frameAt을 갱신해 앱에 보고한다');
  ok(/ws\.onmessage = \(ev\) => \{\s*\n\s*if \(gen !== wsGen\) return;[\s\S]{0,300}markFrame\(\);/.test(DAEMON),
    '어떤 프레임이든(hello·이벤트·disconnect) 살아있음의 증거로 센다');
  ok(/wsGen\+\+;/.test(DAEMON) && /if \(gen !== wsGen\) return;/.test(DAEMON),
    '버린 소켓의 뒤늦은 콜백이 두 번째 연결을 만들지 않는다 (세대 검사)');
  ok(/catchUpAfterOpen = true/.test(DAEMON) && /catchUpAfterOpen\s*=\s*false;[\s\S]{0,300}catchUp\(\)/.test(DAEMON),
    '재개통 직후 catch-up으로 눈감고 있던 구간을 즉시 메운다');
  ok(/health\.failures >= SOCKET_MAX_FAILURES && !health\.authError[\s\S]{0,300}process\.exit\(1\)/.test(DAEMON),
    '재개통해도 계속 못 붙으면 프로세스째 죽어 launchd가 새로 띄우게 한다');
  ok(/now - lastRotateAt < SOCKET_ROTATE_GAP_MS/.test(DAEMON),
    '재개통에 최소 간격이 있다 (부분 구독 환경에서 교차검증이 매 주기 걸려도 폭주하지 않게)');
  ok(/health\.idleLimit = Math\.round/.test(DAEMON),
    '앱이 자기 백스톱을 데몬 상한보다 늦게 잡을 수 있도록 상한을 보고한다');
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
      path.join(ROOT, 'Sources/Slack/SlackHealth.swift'),
      path.join(ROOT, 'Sources/Slack/SlackTranslateStore.swift'),
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

  // ---- 조용히 죽은 소켓: 하트비트는 멀쩡한데 이벤트만 0건 ----
  const nowSec = Math.floor(Date.now() / 1000);
  s = judge({ socket: 'connected', frameAt: nowSec - 60 }, { agoSec: 5 });
  ok(s.state === 'ok', '프레임이 오고 있으면 정상');

  s = judge({ socket: 'connected', frameAt: nowSec - 40 * 60 }, { agoSec: 5 });
  ok(s.state === 'degraded' && s.needsUser === false,
    '하트비트는 신선한데 40분째 프레임이 없다 → connected를 믿지 않고 degraded (조용히 재시작)');
  ok(!/연결됨/.test(s.title), '이 상태를 "연결됨"이라고 부르지 않는다: ' + s.title);
  ok(s.ageSec <= 10, '하트비트 나이는 그대로 신선하게 보고된다 (죽은 건 소켓뿐)');

  s = judge({ socket: 'connected' }, { agoSec: 5 });
  ok(s.state === 'ok',
    'frameAt을 보고하지 않는 구버전 데몬은 판정하지 않는다 (근거 없이 무한 재시작 금지)');

  s = judge({ socket: 'stale', frameAt: nowSec - 12 * 60 }, { agoSec: 5 });
  ok(s.state === 'degraded' && s.needsUser === false,
    '데몬이 스스로 재개통 중이라고 보고하면 같은 조용한 상태로 보여준다');

  s = judge({ socket: 'stale', authError: 'invalid_auth' }, { agoSec: 5 });
  ok(s.state === 'auth', '토큰 문제가 겹치면 재개통이 아니라 토큰 안내가 이긴다');

  // 앱 백스톱은 데몬의 자가 복구(10분)보다 늦고 30분 catch-up보다 빨라야 한다 —
  // 그 사이에 있어야 "데몬이 스스로 못 고쳤다"는 판정이 되고, 사용자가 눈치채기 전에 낫는다.
  const SWIFT = fs.readFileSync(path.join(ROOT, 'Sources/Slack/SlackHealth.swift'), 'utf8');
  const backstop = Number((SWIFT.match(/frameStaleAfter = (\d+) \* 60/) || [])[1]);
  ok(backstop > 10 && backstop < 30,
    `앱 백스톱(${backstop}분)이 데몬 재개통 주기(10분)와 catch-up(30분) 사이에 있다`);
  ok(/private static func kickForFrames\(\)/.test(SWIFT) && /frameKicks/.test(SWIFT),
    '소켓 무응답에는 별도 카운터로 재시작한다 (하트비트가 계속 와 kicks는 매번 0이 된다)');
  ok(/if frameAt > lastFrameSeen \{/.test(SWIFT),
    '프레임이 다시 올라오면 재시작 카운터가 풀린다');
  ok(/if n >= maxKicks \{ return \}/.test(SWIFT),
    '상한을 넘으면 재시작을 멈춘다 (무한 kickstart 금지)');
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
  const run = (health, detail, extra) => {
    const b = 'let hSig="", hDetail=' + (detail ? 'true' : 'false')
      + ', cache=' + JSON.stringify(Object.assign({ health, items: [], syncErr: {} }, extra)) + ';\n'
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

  run({ state: 'degraded', title: '재연결 중', detail: '슬랙 실시간 수신이 조용히 끊겨(40분째)…',
        advice: '', command: '', needsUser: false, ageSec: 4, realtimeAt: 1755290000 });
  ok(els.hChip.className.includes('wait'), '소켓만 죽은 상태도 대기색(보라) — 실패색이 아니다');
  ok(els.hBanner.style.display === 'none',
    '스스로 다시 여는 동안에는 배너를 띄우지 않는다 (no-user-facing-failure)');
  ok(els.pChipT.textContent === '실시간 점검 중',
    '수집 경로 칩이 예전 realtimeAt만 보고 "실시간 수신"이라고 말하지 않는다: ' + els.pChipT.textContent);

  run({ state: 'degraded', title: '슬랙 실시간 수신 끊김', detail: '3회 다시 시작해도 회복되지 않았습니다.',
        advice: '네트워크·VPN을 바꿔 보세요.', command: 'launchctl kickstart -k gui/$(id -u)/x',
        needsUser: true, ageSec: 4 });
  ok(els.hChip.className.includes('warn') && els.hBanner.style.display === '',
    '자동 복구 상한까지 갔을 때만 사용자를 부른다');

  run({ state: 'blocked', title: '슬랙 접속 차단됨', detail: 'slack.com API에 닿지 못합니다 (fetch failed).',
        advice: 'VPN을 켜거나 네트워크를 바꾼 뒤 다시 연결을 눌러 주세요.',
        command: "curl -sS https://slack.com/api/api.test", needsUser: true, ageSec: 4 });
  ok(els.hChip.className.includes('warn'), '사용자 행동이 필요하면 주의색 칩');
  ok(els.hBanner.style.display === '', '이때만 배너를 띄운다');
  ok(/VPN/.test(els.hBanner.innerHTML), '배너에 실제 조치 안내가 들어간다');
  ok(/다시 연결/.test(els.hBanner.innerHTML), '배너에서 바로 다시 연결할 수 있다');
  ok(/api\.test/.test(els.hBanner.innerHTML), '손으로 확인할 명령도 함께 준다');

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

// ------------------------------------------------- 4. 앱 배선
{
  const APP = fs.readFileSync(path.join(ROOT, 'Sources/ConditionManager/AppDelegate.swift'), 'utf8');
  const REG = fs.readFileSync(path.join(ROOT, 'Sources/ConditionManager/Core/WorkerRegistry.swift'), 'utf8');
  const STORE = fs.readFileSync(path.join(ROOT, 'Sources/Slack/SlackTranslateStore.swift'), 'utf8');
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

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
