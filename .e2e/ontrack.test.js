// E2E for derived "on track" parent status. Bound to REAL source: extracts
// goalKids / derivedStatus / statLabel from DashboardContent.swift and asserts the
// rollup rules. on_track is derived from children every render (no stored state),
// so a child going 진행 flips the parent automatically.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
eval(fn('goalKids') + '\n' + fn('derivedStatus') + '\n' + fn('statLabel'));

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const G = (id, status, parent) => ({ id, seq: 0, text: id, parent: parent || '', status: status || 'backlog' });

// Mirrors the screenshot: goal-01 parent of 리포트작성(in_progress) + 지급(backlog).
const parent = G('p1', 'backlog');
const leafTop = G('p2', 'backlog');                 // top-level, no children -> leaf
const child1 = G('c1', 'in_progress', 'p1');
const child2 = G('c2', 'backlog', 'p1');
const goals = [parent, leafTop, child1, child2];

check('parent with in_progress child -> on_track', derivedStatus(goals, parent) === 'on_track', derivedStatus(goals, parent));
check('on_track label is "on track"', statLabel('on_track') === 'on track');
check('top-level leaf -> null (manual buttons)', derivedStatus(goals, leafTop) === null);
check('child (leaf) -> null (manual buttons)', derivedStatus(goals, child1) === null);

// [2] child going in_progress flips parent automatically (derive again, no sync)
const g2 = [G('p1', 'done'), G('c1', 'backlog', 'p1')];
check('parent backlog when no child in progress', derivedStatus(g2, g2[0]) === 'backlog', derivedStatus(g2, g2[0]));
g2[1].status = 'in_progress';
check('flip to on_track after child -> 진행', derivedStatus(g2, g2[0]) === 'on_track');

// all children done -> parent done
const g3 = [G('p', 'backlog'), G('a', 'done', 'p'), G('b', 'done', 'p')];
check('all children done -> parent done', derivedStatus(g3, g3[0]) === 'done', derivedStatus(g3, g3[0]));

// in_progress beats done (any in_progress wins)
const g4 = [G('p', 'backlog'), G('a', 'done', 'p'), G('b', 'in_progress', 'p')];
check('in_progress child wins over done sibling', derivedStatus(g4, g4[0]) === 'on_track');

// parent's OWN stored status is ignored for display (rollup overrides)
const g5 = [G('p', 'in_progress'), G('a', 'backlog', 'p')];
check('parent own status ignored; backlog children -> backlog', derivedStatus(g5, g5[0]) === 'backlog');

// statLabel mapping
check('statLabel done/backlog', statLabel('done') === '완료' && statLabel('backlog') === '대기');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
