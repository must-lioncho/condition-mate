// E2E for the 유형(type) filter — 부모/자식/task multi-select next to 보기·루프.
// Extracts passesTypeFilter + taskRows from the REAL DashboardContent.swift source and
// asserts: (1) empty selection = 모두 (goals as before, no task rows), (2) parent/child
// gating, (3) 'task' keeps task-bearing goals as context and renders their rows,
// (4) the 보기(status) filter also applies to task rows (BLOCKED always shown).
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }

// Globals the extracted functions reference.
let _typeSel = new Set();
const _statusFilter = { backlog: true, in_progress: true, waiting: true, stopped: true, cancelled: false, done: true };
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }

eval(slice('function passesTypeFilter', 'function goalPasses') + '\n'
   + slice('const TASK_ST', '// Energy gauge'));

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

const top = { id: 'a', seq: 1, parent: '', tasks: [] };                                  // 최상위, task 없음
const child = { id: 'b', seq: 2, parent: 'a', tasks: [] };                               // 자식
const withTasks = { id: 'c', seq: 3, parent: '', tasks: [                                // 최상위 + task 3개
  { folder: 'task1-api', id: 'task1', title: 'API 붙이기', status: 'TODO' },
  { folder: 'task2-ui', id: 'task2', title: 'UI', status: 'DONE' },
  { folder: 'task3-block', id: 'task3', title: '막힌 것', status: 'BLOCKED' },
] };

// 1) empty selection = 모두: every goal passes, no task rows rendered
_typeSel = new Set();
check('empty: all goals pass', [top, child, withTasks].map(g => passesTypeFilter(g)), [true, true, true]);
check('empty: no task rows', taskRows(withTasks), '');

// 2) 부모만: top-level passes, child fails
_typeSel = new Set(['parent']);
check('parent only', [top, child, withTasks].map(g => passesTypeFilter(g)), [true, false, true]);

// 3) 자식만: child passes, top-level fails
_typeSel = new Set(['child']);
check('child only', [top, child, withTasks].map(g => passesTypeFilter(g)), [false, true, false]);

// 4) task만: task를 가진 goal만 컨텍스트로 남는다
_typeSel = new Set(['task']);
check('task only keeps task-bearing goal', [top, child, withTasks].map(g => passesTypeFilter(g)), [false, false, true]);

// 5) task rows render with id/title/status labels and the subtask page link
const rows = taskRows(withTasks);
check('rows contain task1 link', rows.includes('/goal?n=3&t=task1-api'), true);
check('rows contain title', rows.includes('API 붙이기'), true);
check('rows contain 3 rows', (rows.match(/taskrow/g) || []).length, 3);
check('DONE row labeled 완료', rows.includes('완료'), true);
check('BLOCKED row labeled 막힘', rows.includes('막힘'), true);

// 6) 보기(status) filter applies to task rows: 완료 off hides DONE, BLOCKED stays
_statusFilter.done = false;
const rows2 = taskRows(withTasks);
check('done off hides DONE task', (rows2.match(/taskrow/g) || []).length, 2);
check('BLOCKED survives status filter', rows2.includes('막힘'), true);
_statusFilter.done = true;

// 7) goal without tasks renders nothing even when task is selected
check('no tasks -> no rows', taskRows(top), '');

console.log(`\n${pass} pass, ${fail} fail`);
process.exit(fail ? 1 : 0);
