#!/usr/bin/env node
// E2E 러너 — 파일을 전부 돌리고, 파일별 통과/실패를 표로 찍고, 하나라도 지면 non-zero 로 끝난다.
//
// ── 왜 이 파일이 생겼나 (2026-08-29) ────────────────────────────────────────
// 지금까지 package.json 의 test 와 test:memo 는 `node a.test.js && node b.test.js && …`
// 였다. && 사슬은 한 파일이 지면 뒤를 통째로 안 돌린다. 그래서 memostage 하나가 지는 동안
// memo 단정 613개 중 446개가 아무에게도 보이지 않았고, 그 뒤에 숨어 있던 낡은 시험 16건이
// 20일 동안 붉은 줄로 방치됐다. 실패를 감추지 않되 뒤를 막지도 않는 것이 이 러너의 목적이다.
//
// 두 번째 목적은 인구조사다. 시험 파일 59개 중 23개(39%)가 어느 npm 스크립트에도 이름이
// 없었고, 그중 18개는 멀쩡히 통과하는데 아무도 안 돌리고 있었다. 그래서 이 러너는 매번
// '게이트 밖에 무엇이 있는지' 를 같이 찍는다 — 다시 조용히 썩지 않게.
//
// 쓰는 법:
//   node run.js            게이트 전부
//   node run.js memo       이름이 memo 로 시작하는 것만
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// ── 게이트 ────────────────────────────────────────────────────────────────
// 여기 이름이 있는 파일이 `npm test` 다. 새 시험 파일을 만들면 여기에 넣는다 —
// 넣지 않으면 러너가 맨 끝에 "아무도 안 돌린다" 고 이름을 불러 준다.
const GATE = [
  // 대시보드 공통
  'ime.test.js', 'source.test.js', 'tier.test.js', 'seq.test.js', 'ontrack.test.js',
  'energy.test.js', 'actioncat.test.js', 'pomodoro.test.js', 'zenflap.test.js',
  'integrations.test.js', 'devicecron.test.js', 'parentsuggest.test.js',
  'loopsessions.test.js',
  // 2026-09-05 — 위임 이슈 목록(/issues). 지키는 것은 화면이 아니라 완료 축의 정직성이다:
  // done/ 폴더에 완료가 아닌 classified 카드가 섞여 있어서, 폴더로 세면 화면이 16 건을
  // 완료라고 거짓말한다. 버킷 표를 Swift 소스에서 뽑아 대조하고, 큐가 이 맥에 있으면
  // 실물 카드로 불변식(미분류 0 · 완료 ≠ done/ 파일 수)까지 확인한다.
  'issues.test.js',
  // 2026-09-06 — 시간 표시의 타임존. 이슈 화면의 세션 줄이 KST 16:31 인 세션을
  // `2026-09-06 07:31`(UTC) 로 찍고 있었다. 원인은 하드코딩이 아니라 변환을 안 한 것 —
  // 저장된 ISO 문자열을 잘라서 그대로 찍었다. 실제 sesHead 를 소스에서 뽑아 호출해
  // 한국·인도(UTC+05:30)·UTC 세 설정에서 값이 갈리는지 보고, 자르기 표기가 화면 코드에
  // 다시 나타나면 진다.
  'timezone.test.js',
  // 2026-08-30 — 루프 컷의 기록. 완료 0건으로 닫아도 경계가 남는가(ReviewStore 를 그대로
  // 컴파일해 판정), 그 빈 컷이 완료 로그에서 걸러지는가, 컷 직후 메모장이 곧바로 깨는가.
  'loopcut.test.js',
  // 2026-08-29 격리 해제 — 넷 다 판정이 붙어 초록이 됐다. draw 는 낡은 계약(정확 일치
  // 정규식 2건 + renderPlugins→plBodyHtml 이사)을 고쳤고, 나머지 셋은 하네스가 빠뜨린
  // 스텁이 원인이었다(제품은 멀쩡했다).
  'draw.test.js', 'goaladd.test.js', 'reorder.test.js', 'tallyhist.test.js',
  // 메모장
  'memostage.test.js', 'memotag.test.js', 'memosort.test.js', 'memoui.test.js',
  'memoultra.test.js', 'memolink.test.js', 'memomove.test.js', 'memofilter.test.js',
  'memoloop.test.js', 'memoloopview.test.js', 'memoboardsync.test.js', 'memocreated.test.js',
  // 2026-08-30 — 컷 직후 같은 분에 적는 줄. 분 단위 생성 스탬프와 초 단위 컷 경계가
  // 어긋나 '쓰면 사라지는' 1분이 있었다.
  'memocutwrite.test.js',
  'memogoalno.test.js', 'memohistory.test.js', 'memoparent.test.js',
  // 2026-08-29 합류 — 어느 스크립트에도 없이 초록이던 것들. 통과하므로 게이트가 붉어지지
  // 않고, 지금까지 아무도 안 돌리던 검증이 살아난다.
  'memofocus.test.js', 'memomerge.test.js', 'memosave.test.js', 'memoundo.test.js',
  'memoultraundo.test.js',
  'celebrate.test.js', 'evidence.test.js', 'exhaust.test.js', 'goalsess.test.js',
  'goalsesshist.test.js', 'harvest.test.js', 'oneline.test.js', 'plan.test.js',
  'reportcsv.test.js', 'screens.test.js', 'tagaudit.test.js', 'typefilter.test.js',
  'viewtrace.test.js', 'zen.test.js',
];

// ── 격리 ──────────────────────────────────────────────────────────────────
// 돌리면 크래시하는데(요약 줄도 못 찍고 exit 1) 아직 판정을 안 받은 것들. 낡은 계약인지
// 살아 있는 결함인지 모르는 채로 게이트에 넣으면 게이트가 '이유 모를 이유' 로 붉어진다.
// 판정이 붙는 즉시 GATE 로 옮기거나 지운다.
const QUARANTINE = {};

const only = process.argv.slice(2).filter((a) => !a.startsWith('-'));
const files = GATE.filter((f) => !only.length || only.some((p) => f.startsWith(p)));

const missing = files.filter((f) => !fs.existsSync(path.join(__dirname, f)));
if (missing.length) { console.log('게이트에 적힌 파일이 없다: ' + missing.join(', ')); process.exit(1); }

// ── 실행 ──────────────────────────────────────────────────────────────────
// 요약 줄의 모양이 파일마다 다르다. 셋 다 읽는다 — 못 읽으면 표에 '-' 가 뜨고,
// 그러면 '몇 개를 검증했는지 아무도 모르는 파일' 이라는 뜻으로 눈에 걸린다.
function summarize(out) {
  let m, last = null;
  const A = /([0-9]+) (?:passed|pass)[,;]\s*([0-9]+) (?:failed|fail)/g;   // 대부분
  while ((m = A.exec(out)) !== null) last = [+m[1], +m[2]];
  if (last) return last;
  const B = out.match(/ALL PASS ([0-9]+) checks/);                        // parentsuggest
  if (B) return [+B[1], 0];
  const C = out.match(/^# pass ([0-9]+)$/m), D = out.match(/^# fail ([0-9]+)$/m);  // node:test TAP
  if (C && D) return [+C[1], +D[1]];
  return null;
}
const rows = [];
console.log('E2E 러너 — ' + files.length + '개 파일. 하나가 져도 뒤를 멈추지 않는다.\n');
for (const f of files) {
  const t0 = Date.now();
  const r = spawnSync(process.execPath, [f], { cwd: __dirname, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const out = (r.stdout || '') + (r.stderr || '');
  const last = summarize(out);
  const ok = r.status === 0;
  const row = {
    f, ok, out,
    pass: last ? last[0] : null,
    fail: last ? last[1] : null,
    ms: Date.now() - t0,
    // 요약 줄도 없이 죽은 것은 '실패' 와 다르다 — 시험이 굴러가지도 못한 것이다.
    crash: !ok && !last,
  };
  rows.push(row);
  console.log('  ' + (ok ? '통과' : (row.crash ? '크래시' : '실패')) + '  ' + f
    + (last ? '  ' + row.pass + '/' + row.fail : '')
    + '  ' + (row.ms / 1000).toFixed(1) + 's');
}

// ── 진 파일의 출력은 통째로 보여 준다 (감추지 않는다) ─────────────────────
const bad = rows.filter((r) => !r.ok);
for (const r of bad) {
  console.log('\n' + '─'.repeat(70) + '\n[' + r.f + '] 출력\n' + '─'.repeat(70));
  console.log(r.out.trimEnd());
}

// ── 표 ────────────────────────────────────────────────────────────────────
const w = Math.max(...rows.map((r) => r.f.length), 6);
console.log('\n' + '='.repeat(70));
console.log('파일'.padEnd(w) + '   통과   실패   시간    결과');
console.log('-'.repeat(70));
for (const r of rows) {
  console.log(r.f.padEnd(w)
    + String(r.pass === null ? '-' : r.pass).padStart(6)
    + String(r.fail === null ? '-' : r.fail).padStart(7)
    + ((r.ms / 1000).toFixed(1) + 's').padStart(8)
    + '    ' + (r.ok ? '통과' : (r.crash ? '크래시' : '실패')));
}
const aP = rows.reduce((s, r) => s + (r.pass || 0), 0);
const aF = rows.reduce((s, r) => s + (r.fail || 0), 0);
console.log('-'.repeat(70));
console.log('파일 ' + rows.length + '개 · 통과 ' + (rows.length - bad.length) + ' · 실패 ' + bad.length
  + '   |   단정 ' + aP + ' 통과 · ' + aF + ' 실패');

// ── 게이트 밖에 무엇이 있는지 매번 말한다 ─────────────────────────────────
if (!only.length) {
  const all = fs.readdirSync(__dirname).filter((f) => f.endsWith('.test.js')).sort();
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'));
  const elsewhere = {};
  for (const [name, cmd] of Object.entries(pkg.scripts)) {
    if (name === 'test' || name === 'test:memo') continue;
    for (const f of cmd.match(/[\w.-]+\.test\.js/g) || []) (elsewhere[f] = elsewhere[f] || []).push(name);
  }
  const out = all.filter((f) => !GATE.includes(f));
  if (out.length) {
    console.log('\n게이트 밖 ' + out.length + '개:');
    for (const f of out) {
      const why = QUARANTINE[f] ? '격리: ' + QUARANTINE[f]
                : elsewhere[f] ? 'npm run ' + elsewhere[f].join(' / ') + ' 에서 돈다'
                : '⚠ 아무 스크립트에도 없다 — 판정하고 GATE 에 넣거나 지워라';
      console.log('  ' + f.padEnd(w) + '  ' + why);
    }
  }
}

console.log('');
process.exit(bad.length ? 1 : 0);
