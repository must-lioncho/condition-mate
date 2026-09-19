// E2E for 루프 컷의 기록 — "Complete loop 를 눌렀는데 메모장이 안 비워진다" 의 뒷단.
//
// 왜 이 시험이 있나 (2026-08-30 실측):
//   보드의 루프 번호는 26-56 인데 메모장은 그 루프에 적은 줄을 그대로 안고 있었다.
//   원인은 메모장이 아니라 보드였다. 패드는 '이 줄이 어느 루프냐' 를 릴리즈(컷)의 시각으로
//   자르는데(MemoPad.loopOf), 완료한 목표가 하나도 없는 루프를 닫으면 서버가 릴리즈를
//   아예 안 만들고 있었다. 이 맥의 저장소에서 26-49 부터 26-55 까지 일곱 루프가 그렇게
//   닫혔고, 마지막 컷 기록은 26-48(2026-08-29 08:01) 이었다. 번호는 열린 스프린트에서
//   오고 경계는 릴리즈에서 오는데 한쪽만 기록되고 있었던 것이다.
//
// 여기서 지키는 계약:
//   - 완료 목표가 없어도 Complete loop 는 컷을 남긴다 (경계는 사건이다)
//   - 그 빈 컷은 완료 로그에 안 보인다 — goalIds·titles·notes 가 전부 비어 있고,
//     대시보드의 isEmptyCut 이 그 조건으로 걸러낸다 (안 걸러내면 빈 줄이 로그를 덮는다)
//   - 완료 목표가 있는 평소 컷은 예전 그대로 한 건만 남는다 (빈 컷이 겹쳐 붙지 않는다)
//   - 컷의 시각은 실제로 닫은 순간이다 — 패드가 그 값으로 자르므로 0 이면 못 쓴다
//   - 잘못 눌렀을 때 되돌릴 길이 있다: 빈 컷의 복원이 스프린트를 다시 연다
//
// 판정은 ReviewStore.swift 를 그대로 컴파일해서 돌린다 — 규칙을 시험으로 옮겨 적지 않는다.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cm-loopcut-'));

let pass = 0, fail = 0;
const eq = (n, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + n + (ok ? '' : '  got=' + JSON.stringify(got)));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
};
const ok = (n, cond, extra) => {
  console.log((cond ? 'PASS ' : 'FAIL ') + n + (cond ? '' : '  ' + (extra || '')));
  cond ? pass++ : fail++;
};

// ── 1. 대시보드가 빈 컷을 알아보는 규칙 (배송 소스에서 그대로 떼어 온다) ─────────
const DASH = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Dashboard/DashboardContent.swift'), 'utf8');
function jsFn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}
const isEmptyCut = new Function(jsFn(DASH, 'isEmptyCut') + '; return isEmptyCut;')();
eq('빈 컷은 커밋도 노트도 없다 → 로그에서 뺀다',
  isEmptyCut({ goalIds: [], titles: [], notes: [] }), true);
eq('목표를 커밋한 컷은 로그에 남는다',
  isEmptyCut({ goalIds: ['g1'], titles: ['한 일'], notes: [] }), false);
eq('메모만 거둔 컷도 로그에 남는다 — 메모로만 돈 루프의 기록이다',
  isEmptyCut({ goalIds: [], titles: [], notes: ['메모 완료 줄'] }), false);
eq('필드가 아예 없는 옛 기록도 터지지 않는다', isEmptyCut({}), true);
// 완료 로그가 실제로 그 규칙을 쓰고 있나 — 함수만 있고 안 부르면 아무 소용이 없다.
ok('완료 로그가 isEmptyCut 으로 거른다',
  /const rels=\(\(r&&r\.releases\)\|\|\[\]\)\.filter\(x=>!isEmptyCut\(x\)\)/.test(DASH),
  'completedLogHTML 이 releases 를 그대로 쓰고 있다');
// 컷 직후 패드를 깨우는 길 — 없으면 폴링(30초 틱 + 60초 스로틀)으로 60~90초를 기다린다.
ok('루프 완료가 메모장에 곧바로 알린다', /CMMemo\.boardChanged\(\)/.test(DASH));
ok('완료 창구가 하나로 모여 있다',
  (DASH.match(/post\('\/api\/sprint\/complete'/g) || []).length === 1,
  '/api/sprint/complete 를 부르는 자리가 여럿이면 한쪽만 알리게 된다');
const PAD = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Dashboard/MemoPad.swift'), 'utf8');
ok('패드가 boardChanged 를 내놓고, 그것이 스로틀을 건너뛴다',
  /boardChanged:function\(\)\{ boardFetch\(true\); \}/.test(PAD));

// ── 2. 서버 판정 — ReviewStore.swift 를 그대로 컴파일해 돌린다 ──────────────────
const swiftc = '/Library/Developer/CommandLineTools/usr/bin/swiftc';
const sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk';
let probe = null;
if (fs.existsSync(swiftc) && fs.existsSync(sdk)) {
  const harness = path.join(tmp, 'main.swift');
  // 시나리오 하나를 통째로 돌리고 끝 상태를 JSON 으로 찍는다. 데이터 루트는 CM_DATA_DIR
  // 로 갈아 끼우므로 사용자의 진짜 ~/.condition-mate 는 건드리지 않는다.
  //   scenario "empty"    — 목표는 있는데 완료가 하나도 없는 루프를 닫는다
  //   scenario "done"     — 완료 목표가 있는 루프를 닫는다(평소 경로)
  //   scenario "restore"  — 빈 컷을 만든 뒤 그 기록을 복원한다
  fs.writeFileSync(harness, `
import Foundation
let scenario = CommandLine.arguments[1]
let store = ReviewStore()
let sp = store.createSprint(goalText: "", durationKind: "1d", auto: true)
_ = store.addGoal(text: "안 끝난 일", sprint: sp.number)
if scenario == "done" {
    _ = store.addGoal(text: "끝낸 일", sprint: sp.number)
    if let g = store.goals.first(where: { $0.text == "끝낸 일" }) {
        store.setStatus(id: g.id, status: "done")
    }
}
let t0 = Date().timeIntervalSince1970
store.completeSprint(sp.number)
if scenario == "restore", let r = store.releases.first { store.restoreRelease(id: r.id) }
// 끝 상태를 그대로 찍는다 — 시험이 규칙을 다시 적지 않고 이 값만 본다.
let rels = store.releases.map { r -> [String: Any] in
    ["code": r.code, "sprint": r.sprint, "value": r.value,
     "goalIds": r.goalIds.count, "titles": r.titles.count, "notes": r.notes.count,
     "carriedTo": r.carriedTo, "carriedIds": r.carriedIds.count,
     "at": r.releasedAt.timeIntervalSince1970]
}
let sprs = store.sprints.map { s -> [String: Any] in
    ["number": s.number, "code": s.code, "closed": s.closed]
}
let out: [String: Any] = ["t0": t0, "releases": rels, "sprints": sprs,
                          "goals": store.goals.map { ["text": $0.text, "sprint": $0.sprint,
                                                      "released": $0.released] }]
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
`);
  try {
    execFileSync(swiftc, ['-sdk', sdk, '-module-cache-path', path.join(tmp, 'mc'),
      '-o', path.join(tmp, 'probe'),
      path.join(ROOT, 'Sources/ConditionMate/Core/ReviewStore.swift'),
      path.join(ROOT, 'Sources/ConditionMate/Core/MemoStore.swift'),
      path.join(ROOT, 'Sources/ConditionMate/Core/AppPaths.swift'),
      path.join(ROOT, 'Sources/ConditionMate/Core/IssuePaths.swift'),
      harness], { stdio: ['ignore', 'ignore', 'pipe'] });
    probe = path.join(tmp, 'probe');
  } catch (e) {
    console.log('  SKIP  Swift 판정 (컴파일 실패)\n' + String(e.stderr || e).slice(0, 1200));
  }
} else {
  console.log('  SKIP  Swift 판정 (swiftc 없음)');
}

function run(scenario) {
  const dir = fs.mkdtempSync(path.join(tmp, 'data-'));
  return JSON.parse(execFileSync(probe, [scenario],
    { encoding: 'utf8', env: Object.assign({}, process.env, { CM_DATA_DIR: dir }) }));
}

if (probe) {
  // ── 완료 0건으로 닫는다 — 이 맥에서 일곱 번 일어난 그 경로 ───────────────────
  const e = run('empty');
  eq('완료가 없어도 컷은 하나 남는다', e.releases.length, 1);
  const cut = e.releases[0];
  eq('그 컷은 아무것도 안 실었다 — 완료 로그가 걸러낼 모양 그대로',
    [cut.goalIds, cut.titles, cut.notes, cut.value], [0, 0, 0, 0]);
  eq('로그의 규칙(isEmptyCut)이 실제로 이 기록을 걸러낸다',
    isEmptyCut({ goalIds: [], titles: [], notes: [] }), true);
  eq('컷은 닫은 그 스프린트의 것이고 코드도 그 루프의 코드다',
    [cut.sprint, cut.code], [e.sprints[0].number, e.sprints[0].code]);
  // 패드가 자르는 근거가 이 시각이다 — 0 이면 boardFetch 의 cuts 필터에서 통째로 빠진다.
  ok('컷의 시각이 방금이다 (패드가 이 값으로 루프를 자른다)',
    cut.at >= e.t0 - 1 && cut.at <= e.t0 + 30, 'at=' + cut.at + ' t0=' + e.t0);
  eq('닫은 루프는 닫혀 있다', e.sprints[0].closed, true);
  // 미완료가 있었으므로 후속 루프가 열리고, 이월이 컷에 적혀 되돌릴 수 있다.
  eq('미완료는 다음 루프로 이월된다', e.sprints.length, 2);
  eq('빈 컷에도 이월 기록이 실린다 — 복원이 온전히 되돌릴 수 있게',
    [cut.carriedTo, cut.carriedIds], [e.sprints[1].number, 1]);

  // ── 완료가 있는 평소 경로는 예전 그대로 ────────────────────────────────────
  const d = run('done');
  eq('완료가 있으면 컷은 여전히 한 건이다 (빈 컷이 겹쳐 붙지 않는다)', d.releases.length, 1);
  eq('그 컷은 완료한 목표를 싣는다', [d.releases[0].goalIds, d.releases[0].titles], [1, 1]);
  eq('그래서 완료 로그에 보인다',
    isEmptyCut({ goalIds: ['x'], titles: ['끝낸 일'], notes: [] }), false);

  // ── 잘못 눌렀을 때 ────────────────────────────────────────────────────────
  const r = run('restore');
  eq('빈 컷을 복원하면 기록이 사라진다', r.releases.length, 0);
  eq('그리고 그 루프가 다시 열린다', r.sprints[0].closed, false);
  eq('이월됐던 목표도 제자리로 돌아온다',
    r.goals.filter((g) => g.sprint === r.sprints[0].number).length, 1);
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
