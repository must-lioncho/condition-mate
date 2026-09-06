// 살아 있는 앱이 실제로 내보낸 페이지에서 진짜 JS 를 뽑아 돌린다.
// 소스가 아니라 /Applications/ConditionMate.app 이 서빙한 바이트가 입력이다.
const fs = require('fs');
const SC = process.argv[2];
const H = fs.readFileSync(SC + '/live-issues.html', 'utf8');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got) + (ok ? '' : '  want=' + JSON.stringify(want)));
}

// 1) 페이지가 실어 보낸 CMTimeFilter 모듈 본체
const m = /window\.CMTimeFilter = window\.CMTimeFilter \|\| \(function\(\)\{[\s\S]*?\n\}\)\(\);/.exec(H);
if (!m) throw new Error('서빙된 페이지에서 CMTimeFilter 모듈을 못 찾았다');
global.window = globalThis;
global.document = { getElementById: () => null, createElement: () => ({}), head: { appendChild() {} } };
eval(m[0]);
const T = window.CMTimeFilter;

// 2) 페이지가 실어 보낸 진짜 esc / tdisp / sesHead
// nth: 같은 이름이 페이지에 여럿 있다. 레일의 esc 는 DOM 을 쓰는 다른 구현이고,
// sesHead 가 실제로 부르는 것은 같은 스크립트 블록 안의 IssuesContent 쪽 esc(2 번째)다.
function fnFrom(src, name, nth) {
  let i = -1;
  for (let n = 0; n < (nth || 1); n++) i = src.indexOf('function ' + name + '(', i + 1);
  if (i < 0) throw new Error(name + ' 를 서빙된 페이지에서 못 찾았다');
  let d = 0, started = false;
  for (let k = i; k < src.length; k++) {
    if (src[k] === '{') { d++; started = true; }
    else if (src[k] === '}') { d--; if (started && d === 0) return src.slice(i, k + 1); }
  }
  throw new Error(name + ' 의 끝을 못 찾았다');
}
eval(fnFrom(H, 'esc', 2) + '\n' + fnFrom(H, 'tdisp') + '\n' + fnFrom(H, 'sesHead'));

// 3) 살아 있는 앱이 방금 돌려준 진짜 레코드
const j = JSON.parse(fs.readFileSync(SC + '/issues.json', 'utf8'));
const card = (j.cards || []).find(c => /\+0000$/.test(String(c.versionFirstSeen || '')));
if (!card) throw new Error('UTC(+0000) 로 새로 저장된 레코드를 라이브 응답에서 못 찾았다');
const FS = card.versionFirstSeen;
console.log('실측 레코드: id=' + card.id);
console.log('  versionFirstSeen(저장값) = ' + FS + '   ← 새로 쓴 시각이 UTC 다');
console.log('  captured(카드 파일 원본)  = ' + card.captured + '   ← 옛 오프셋 그대로 읽는다\n');

// 카드 화면이 실제로 부르는 모양: tdisp(v.firstSeen,10) 과 tdisp(v.firstSeen,16)
function underTZ(z, f) { window.CM_TZ = z; return f(); }

check('한국  · 버전 줄 (분까지)', underTZ('Asia/Seoul', () => T.isoDisp(FS, 16)), '2026-09-07 02:01');
check('한국  · 버전 줄 (날짜만) — 날짜 경계를 넘는다', underTZ('Asia/Seoul', () => T.isoDisp(FS, 10)), '2026-09-07');
check('인도  · 버전 줄 (분까지) — 30분 오프셋', underTZ('Asia/Kolkata', () => T.isoDisp(FS, 16)), '2026-09-06 22:31');
check('인도  · 버전 줄 (날짜만)', underTZ('Asia/Kolkata', () => T.isoDisp(FS, 10)), '2026-09-06');
check('UTC   · 버전 줄 (분까지)', underTZ('UTC', () => T.isoDisp(FS, 16)), '2026-09-06 17:01');

// 카드가 그대로 들고 있는 옛 오프셋(+0530) 값도 같은 순간으로 읽는가
const CAP = card.captured;
check('옛 +0530 저장분 · 한국 (같은 순간, 날짜 넘음)', underTZ('Asia/Seoul', () => T.isoDisp(CAP, 16)), '2026-09-07 01:55');
check('옛 +0530 저장분 · 인도', underTZ('Asia/Kolkata', () => T.isoDisp(CAP, 16)), '2026-09-06 22:25');
check('옛 +0530 저장분 · UTC', underTZ('UTC', () => T.isoDisp(CAP, 16)), '2026-09-06 16:55');

// 세션 줄 — 라이언이 밑줄 그은 바로 그 줄. 문제 사례의 순간을 그대로 넣는다.
const S = { sessionId: '97cc3cc25f0a4d3b', file: '', cwd: '', projectDir: '',
            startedAt: '2026-09-06T07:31:12.345Z', userTurns: 2, writeCount: 3 };
check('세션 줄 · 한국  (문제 사례 07:31 → 16:31)', underTZ('Asia/Seoul', () => sesHead(S)),
      '세션 <b>97cc3cc2</b> · 2026-09-06 16:31 · 사람 말 2 번 · 쓴 파일 3 개');
check('세션 줄 · 인도  (30분 오프셋)', underTZ('Asia/Kolkata', () => sesHead(S)),
      '세션 <b>97cc3cc2</b> · 2026-09-06 13:01 · 사람 말 2 번 · 쓴 파일 3 개');
check('세션 줄 · UTC   (이때만 07:31 이 맞다)', underTZ('UTC', () => sesHead(S)),
      '세션 <b>97cc3cc2</b> · 2026-09-06 07:31 · 사람 말 2 번 · 쓴 파일 3 개');

// 설정을 되돌리면 값도 되돌아온다 — 굳지 않는다
const seq = ['Asia/Seoul', 'Asia/Kolkata', 'Asia/Seoul', 'UTC', 'Asia/Kolkata']
  .map(z => underTZ(z, () => T.isoDisp(FS, 16)));
check('설정 5 회 전환이 매번 다시 계산된다', seq.join(' | '),
      '2026-09-07 02:01 | 2026-09-06 22:31 | 2026-09-07 02:01 | 2026-09-06 17:01 | 2026-09-06 22:31');

// 서빙된 바이트에 옛 자르기가 없다
check('서빙된 페이지에 세션 줄 옛 자르기 없음', H.includes("esc(String(S.startedAt||'').replace"), false);
check('서빙된 페이지에 턴 줄 옛 자르기 없음',   H.includes("esc(String(t.at||'').replace"), false);
check('서빙된 페이지에 보고 줄 옛 자르기 없음', H.includes("esc(String(S.lastAt||'').replace"), false);
check('서빙된 페이지에 인도 옵션이 있다', H.includes("['Asia/Kolkata','IST (UTC+5:30)']"), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
