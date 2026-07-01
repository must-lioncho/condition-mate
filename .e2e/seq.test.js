// E2E for stable goal numbers (seq). Bound to REAL source: extracts gnum / dropOn /
// setParentByNumber from DashboardContent.swift, and mirrors the REAL backend
// ReviewStore.reorderGoals (which reorders whole Goal objects, preserving every
// field incl. seq). Asserts: drag reorder changes ORDER but never the seq badge,
// and 부모# references resolve by stable seq.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  // grab `function name(...) { ... }` up to its matching closing brace at column 0-ish.
  const start = SRC.indexOf('function ' + name);
  if (start < 0) throw new Error('no fn ' + name);
  // these are one-liner-ish helpers terminated by '\n}' or '; }'
  let i = SRC.indexOf('(', start), depth = 0, j = SRC.indexOf('{', i);
  for (let k = j; k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
// real helpers from source
eval(fn('gnum') + '\n' + fn('dropOn') + '\n' + fn('setParentByNumber'));

// Mirror of ReviewStore.reorderGoals (Sources/.../ReviewStore.swift) — preserves objects.
function backendReorder(goals, order) {
  const byId = {}; goals.forEach(g => byId[g.id] = g);
  const placed = new Set(), out = [];
  order.forEach(id => { if (byId[id] && !placed.has(id)) { out.push(byId[id]); placed.add(id); } });
  goals.forEach(g => { if (!placed.has(g.id)) out.push(g); });
  return out.length === goals.length ? out : goals;
}

// globals/stubs the extracted functions reference
let _goals, _dragFrom = null, lastPost = null, loaded = 0;
global.document = { querySelectorAll: () => ({ forEach: () => {} }) };
global.post = (path, obj) => { lastPost = { path, obj }; return Promise.resolve(); };
global.load = () => { loaded++; };
const ev = () => ({ preventDefault() {}, dataTransfer: { dropEffect: '' } });

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

// --- Scenario: two goals with NON-sequential seq (as after earlier deletes/adds) ---
function mkGoals() {
  return [
    { id: 'uuid-A', seq: 6, text: '주보상패키지 지급', parent: '' },
    { id: 'uuid-B', seq: 4, text: 'supertrust roadmap', parent: '' },
  ];
}

// badges reflect seq as goal-NN, not position
_goals = mkGoals();
check('badge uses goal-NN seq', gnum(_goals[0]) === 'goal-06' && gnum(_goals[1]) === 'goal-04', `${gnum(_goals[0])},${gnum(_goals[1])}`);

// drag goal at position 1 (seq 4) to top (position 0)
_goals = mkGoals(); _dragFrom = 1;
global.dropOn = eval('(' + fn('dropOn') + ')'); // ensure callable
dropOn(ev(), 0);
const orderSent = lastPost.obj.order;
check('reorder posts id order (B then A)', JSON.stringify(orderSent) === JSON.stringify(['uuid-B', 'uuid-A']), JSON.stringify(orderSent));

// apply backend reorder, re-read badges
const after = backendReorder(mkGoals(), orderSent);
check('order changed: B now first', after[0].id === 'uuid-B' && after[1].id === 'uuid-A');
check('seq STABLE after reorder', gnum(after[0]) === 'goal-04' && gnum(after[1]) === 'goal-06',
  `badges now ${gnum(after[0])},${gnum(after[1])} (must stay goal-04,goal-06 — not goal-01,goal-02)`);
check('ids unchanged', after[0].seq === 4 && after[1].seq === 6 && after[0].id === 'uuid-B');

// --- 부모# references resolve by stable seq, even after reorder ---
_goals = after; lastPost = null;
setParentByNumber('uuid-A', '4');   // make A child of seq-4 (B)
check('parent set by seq -> correct parent id', lastPost && lastPost.path === '/api/goal/parent'
  && lastPost.obj.id === 'uuid-A' && lastPost.obj.parent === 'uuid-B', JSON.stringify(lastPost && lastPost.obj));

// 부모# accepts the "goal-NN" label too, not just the bare number
_goals = after; lastPost = null;
setParentByNumber('uuid-A', 'goal-04');
check('parent set by "goal-04" label', lastPost && lastPost.obj.parent === 'uuid-B', JSON.stringify(lastPost && lastPost.obj));

// invalid seq -> revert (load), no post
_goals = after; lastPost = null; loaded = 0;
setParentByNumber('uuid-A', '99');
check('unknown seq reverts via load(), no parent post', loaded === 1 && lastPost === null);

// self-reference rejected
_goals = after; lastPost = null; loaded = 0;
setParentByNumber('uuid-B', '4');   // B has seq 4 -> self
check('self seq rejected', loaded === 1 && lastPost === null);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
