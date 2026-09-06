// E2E for 시간 표시의 타임존 — 저장은 UTC, 화면은 설정한 타임존.
//
// 왜 이 파일이 있는가 (2026-09-06). 이슈 화면의 세션 줄이 이렇게 찍혀 있었다:
//   `세션 97cc3cc2 · 2026-09-06 07:31 · 사람 말 2 번 · 쓴 파일 3 개`
// 그 세션은 KST 16:31 에 시작했다. 07:31 은 UTC 다. 원인은 하드코딩된 타임존이 아니라
// **변환을 아예 안 한 것**이었다 — 화면이 저장된 ISO 문자열을
// `.replace('T',' ').slice(0,16)` 으로 잘라 그대로 찍었다. 자르기는 변환이 아니다.
//
// 이 파일이 지키는 것 셋:
//   1) 화면에 시각을 찍는 자리는 CMTimeFilter.isoDisp 를 통과한다. 새 자리에서 자르기를
//      다시 쓰면 여기서 진다 — 그 회귀는 사람 눈에 3시간이나 3시간 30분 어긋난 숫자로만
//      보이고, 어긋난 숫자는 틀렸다고 소리치지 않는다.
//   2) isoDisp 가 한국(UTC+9)과 인도(UTC+05:30)에서 실제로 맞는 값을 낸다. 30분 오프셋이
//      깨지기 쉬운 자리라 인도를 축으로 둔다.
//   3) 앞으로 생성되는 시각은 UTC 로 저장된다. 기존 데이터는 건드리지 않으므로, 옛
//      `+0530`·`+0900` 값도 계속 정확히 읽혀야 한다 — 포맷의 `Z` 가 그것을 보장한다.
//
// 하네스는 실제 소스를 읽는다. 빌드 없이 돈다.
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'Sources', 'ConditionMate');
const D = (f) => fs.readFileSync(path.join(SRC, 'Dashboard', f), 'utf8');
const C = (f) => fs.readFileSync(path.join(SRC, 'Core', f), 'utf8');
const CMF = D('CMTimeFilter.swift');
const IC = D('IssuesContent.swift');
const LE = D('LoopEngineeringContent.swift');
const BG = D('BGMPlayerContent.swift');
const SR = D('SessionRail.swift');
const DC = D('DashboardContent.swift');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ── 실제 CMTimeFilter.js 를 소스에서 뽑아 돌린다 ────────────────────────────
const jsm = /static let js = #"""\n([\s\S]*?)\n"""#/.exec(CMF);
if (!jsm) throw new Error('CMTimeFilter.swift 안에서 js 블록을 못 찾았다');
// 브라우저에서는 `window.X` 가 곧 전역 `X` 다. 화면 코드가 `window.CMTimeFilter &&
// CMTimeFilter.isoDisp` 처럼 쓰므로 node 에서도 그 동일성을 세워 준다 — 안 그러면 제품이
// 아니라 하네스가 진다.
global.window = globalThis;
global.document = { getElementById: () => null, createElement: () => ({}), head: { appendChild() {} } };
eval(jsm[1]);
const T = window.CMTimeFilter;
check('CMTimeFilter 가 isoDisp 를 내보낸다', typeof T.isoDisp, 'function');

// 스크린샷의 실제 문제 사례. 하네스 트랜스크립트의 timestamp 는 UTC 다.
const REAL = '2026-09-06T07:31:12.345Z';
check('회귀의 모양 — 옛 자르기가 찍던 값', String(REAL).replace('T', ' ').slice(0, 16), '2026-09-06 07:31');

window.CM_TZ = 'Asia/Seoul';
check('한국(UTC+9)', T.isoDisp(REAL, 16), '2026-09-06 16:31');
check('한국 · 날짜만', T.isoDisp(REAL, 10), '2026-09-06');
check('한국 · 초까지', T.isoDisp(REAL, 19), '2026-09-06 16:31:12');
window.CM_TZ = 'Asia/Kolkata';
check('인도(UTC+05:30) — 30분 오프셋', T.isoDisp(REAL, 16), '2026-09-06 13:01');
check('인도 · 초까지', T.isoDisp(REAL, 19), '2026-09-06 13:01:12');
window.CM_TZ = 'UTC';
check('UTC 설정', T.isoDisp(REAL, 16), '2026-09-06 07:31');

// 설정 변경이 반영되는가. 레일은 저장 뒤 location.reload 로 새 CM_TZ 를 주입받으므로,
// "CM_TZ 만 바꾸면 같은 입력이 다른 값을 낸다" 가 곧 그 축이다 — 값을 캐시해 굳으면 진다.
const seq = [];
['Asia/Seoul', 'Asia/Kolkata', 'Asia/Seoul', 'UTC', 'Asia/Kolkata'].forEach(z => {
  window.CM_TZ = z; seq.push(T.isoDisp(REAL, 16));
});
check('한국↔인도 왕복 전환이 매번 다시 계산된다', seq.join(' | '),
  '2026-09-06 16:31 | 2026-09-06 13:01 | 2026-09-06 16:31 | 2026-09-06 07:31 | 2026-09-06 13:01');

// 두 존이 서로 다른 날을 부르는 창(UTC 18:00~20:29).
window.CM_TZ = 'Asia/Seoul';   check('날짜 경계 · 한국 04:00 (D+1)', T.isoDisp('2026-09-06T19:00:00Z', 16), '2026-09-07 04:00');
window.CM_TZ = 'Asia/Kolkata'; check('날짜 경계 · 인도 00:30 (D+1)', T.isoDisp('2026-09-06T19:00:00Z', 16), '2026-09-07 00:30');

// 저장 포맷이 섞여 있다 — 셋 다 받는다.
window.CM_TZ = 'Asia/Seoul';
check('옛 IST 저장분 `+0530`', T.isoDisp('2026-09-06T13:01:12+0530', 16), '2026-09-06 16:31');
check('sitemap.json 모양 `+09:00`', T.isoDisp('2026-07-12T21:10:05+09:00', 16), '2026-07-12 21:10');
check('새 저장 모양 `+0000`', T.isoDisp('2026-09-06T07:31:12+0000', 16), '2026-09-06 16:31');
// 오프셋이 없는 값은 어느 지역인지 알 수 없다. 지어내지 않고 적힌 대로 둔다 —
// 기존 데이터를 손대지 않는다는 이번 조건이 여기서 코드로 서 있다.
check('오프셋 없는 벽시계는 적힌 그대로', T.isoDisp('2026-09-06T07:31:12', 16), '2026-09-06 07:31');
check('빈 값', T.isoDisp('', 16), '');
check('시각이 아닌 값', T.isoDisp('직접 고침', 16), '직접 고침');

// ── 이슈 화면의 세션 줄을 실제 소스에서 뽑아 그린다 ─────────────────────────
// 문자열 매칭이 아니라 진짜 호출이다. 이 줄이 스크린샷에 찍힌 바로 그 줄이다.
function fnFrom(src, name) {
  const i = src.indexOf('function ' + name + '(');
  if (i < 0) throw new Error(name + ' 을 소스에서 못 찾았다');
  let d = 0, started = false;
  for (let j = src.indexOf('{', i); j < src.length; j++) {
    const ch = src[j];
    if (ch === '{') { d++; started = true; }
    else if (ch === '}') { d--; if (started && d === 0) return src.slice(i, j + 1); }
  }
  throw new Error(name + ' 의 끝을 못 찾았다');
}
eval(fnFrom(IC, 'esc') + '\n' + fnFrom(IC, 'tdisp') + '\n' + fnFrom(IC, 'sesHead'));
const S = { sessionId: '97cc3cc25f0a4d3b', file: '', cwd: '', projectDir: '',
            startedAt: REAL, userTurns: 2, writeCount: 3 };
window.CM_TZ = 'Asia/Seoul';
check('세션 줄 · 한국', sesHead(S), '세션 <b>97cc3cc2</b> · 2026-09-06 16:31 · 사람 말 2 번 · 쓴 파일 3 개');
window.CM_TZ = 'Asia/Kolkata';
check('세션 줄 · 인도', sesHead(S), '세션 <b>97cc3cc2</b> · 2026-09-06 13:01 · 사람 말 2 번 · 쓴 파일 3 개');
window.CM_TZ = 'UTC';
check('세션 줄 · UTC 설정이면 07:31 이 맞다', sesHead(S), '세션 <b>97cc3cc2</b> · 2026-09-06 07:31 · 사람 말 2 번 · 쓴 파일 3 개');

// ── 자르기가 화면 코드에 다시 나타나지 않는다 ───────────────────────────────
// `slice(0,10)` 자체는 커밋 해시 같은 데도 쓰이므로, ISO 를 벽시계로 찍는 모양만 잡는다.
const SLICEY = /\.replace\('T',\s*' '\)\.slice\(0,\s*1[069]\)|\.slice\(0,\s*1[069]\)\.replace\('T',\s*' '\)/g;
[['IssuesContent', IC], ['LoopEngineeringContent', LE], ['BGMPlayerContent', BG]].forEach(([n, s]) => {
  check(n + ' 에 ISO 자르기 표기가 남아 있지 않다', (s.match(SLICEY) || []).length, 0);
});
check('IssuesContent 가 tdisp 를 쓴다', (IC.match(/tdisp\(/g) || []).length >= 6, true);
check('LoopEngineeringContent 가 tdisp 를 쓴다', (LE.match(/tdisp\(/g) || []).length >= 6, true);
check('BGMPlayerContent 가 isoDisp 를 쓴다', /CMTimeFilter\.isoDisp\(_scMap\.generatedAt/.test(BG), true);

// ── 셀렉터에 인도가 있다 ────────────────────────────────────────────────────
// 없으면 `시스템` 으로만 갈 수 있고, 그건 맥 설정을 바꿔야 한다는 뜻이다.
check('레일 설정 메뉴에 Asia/Kolkata', /\['Asia\/Kolkata','IST \(UTC\+5:30\)'\]/.test(SR), true);
check('헤더 셀렉터에 Asia/Kolkata', /\['Asia\/Kolkata','IST \(UTC\+5:30\)'\]/.test(DC), true);

// ── 저장은 UTC 다 ───────────────────────────────────────────────────────────
// 세 원장이 `yyyy-MM-dd'T'HH:mm:ssZ` 로 시각을 남긴다. 포매터의 기본 타임존은 머신 로컬이라
// 이 맥(Asia/Kolkata)에서 `+0530` 이 파일에 박혔다. 앞으로 생성되는 것만 UTC 로 바꾼다.
[['WorkQueueVersionLedger.swift', C('WorkQueueVersionLedger.swift')],
 ['IssueArchiveStore.swift', C('IssueArchiveStore.swift')],
 ['WorkQueueLiveStore.swift', C('WorkQueueLiveStore.swift')]].forEach(([n, s]) => {
  const i = s.indexOf('"yyyy-MM-dd\'T\'HH:mm:ssZ"');
  const head = s.slice(Math.max(0, i - 700), i);
  check(n + ' 의 저장 포매터가 UTC 로 고정돼 있다',
        /f\.timeZone = TimeZone\(identifier: "UTC"\)/.test(head), true);
});
// 마이그레이션은 하지 않는다 — 그러니 옛 값을 읽는 경로가 살아 있어야 한다.
check('포맷에 `Z` 가 남아 있다 (옛 오프셋 값을 그대로 파싱한다)',
      /"yyyy-MM-dd'T'HH:mm:ssZ"/.test(C('WorkQueueLiveStore.swift')), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
