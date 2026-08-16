// E2E for the parent-level AI-work logic. Bound to REAL source: extracts the thresholds
// (CONC_ENERGY/CONC_AGENT/ROI_HI/ROI_LO) and the helpers (goalKids / derivedStatus /
// activeParent / concCount / energySum / roiOf / roiClass / energyGauge) from
// DashboardContent.swift and asserts the gating + energy-cap + ROI-band rules.
//   - energy/agent/token/value are managed at the PARENT level, not per leaf task
//   - the unit of concurrency is an ACTIVE PARENT (rollup on_track = a child in progress)
//   - 1+ active parent => agents/tokens/value/ROI ; 2+ active parents => energy + gauge
//   - summed parent energy over 100% => over-capacity warning
//   - ROI = value / tokens(K), banded hi/mid/lo
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
// Pull the threshold constants straight from source so the test tracks any retune.
function consts(names) {
  return names.map(n => {
    // Names may be comma-chained on one line (const A=2, B=3;), so match the name
    // followed by '=' rather than requiring a leading 'const'.
    const m = SRC.match(new RegExp('\\b' + n + '\\s*=\\s*([0-9.]+)'));
    if (!m) throw new Error('no const ' + n);
    // Emit as var, not const: a const declared inside a direct eval is block-scoped to
    // the eval and would not leak to module scope (function declarations do leak, which
    // is how the extracted helpers below become callable). var leaks the same way.
    return 'var ' + n + '=' + m[1] + ';';
  }).join('\n');
}
eval(consts(['CONC_ENERGY', 'CONC_AGENT', 'ROI_HI', 'ROI_LO']) + '\n'
  + fn('goalKids') + '\n' + fn('derivedStatus') + '\n' + fn('activeParent') + '\n'
  + fn('concCount') + '\n' + fn('energySum') + '\n' + fn('roiOf') + '\n'
  + fn('roiClass') + '\n' + fn('energyGauge'));

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
// P = parent goal (top-level, carries the AI-work fields); K = child/leaf task.
// A parent is "active" (on_track) when one of its children is in_progress.
const P = (id, energy, tokens, value) => ({ id, seq: 0, text: id, parent: '', status: 'backlog', energy: energy || 0, agents: [], tokens: tokens || 0, value: value || 0 });
const K = (id, parent, status) => ({ id, seq: 0, text: id, parent, status: status || 'backlog', energy: 0, agents: [], tokens: 0, value: 0 });

// --- thresholds: agent inputs from 1 active parent, energy from 2 (real parallelism) ---
check('CONC_ENERGY is 2', CONC_ENERGY === 2, String(CONC_ENERGY));
check('CONC_AGENT is 1', CONC_AGENT === 1, String(CONC_AGENT));
check('agent threshold <= energy threshold', CONC_AGENT <= CONC_ENERGY);

// --- concurrency unit is the ACTIVE PARENT, not the leaf task ---
const solo = [P('p1', 40), K('c1', 'p1', 'in_progress'), P('p2', 0), K('c2', 'p2', 'backlog')];
check('one active parent -> conc 1', concCount(solo) === 1, String(concCount(solo)));
const two = [P('p1', 40), K('c1', 'p1', 'in_progress'), P('p2', 30), K('c2', 'p2', 'in_progress')];
check('two active parents -> conc 2', concCount(two) === 2);
// A childless top-level goal set in_progress is NOT a parent -> contributes nothing.
const leafOnly = [{ id: 'x', seq: 0, text: 'x', parent: '', status: 'in_progress', energy: 50, agents: [], tokens: 0, value: 0 }];
check('childless in_progress goal -> conc 0 (parent-only)', concCount(leafOnly) === 0, String(concCount(leafOnly)));

// --- gating: gauge hidden below 2 active parents, shown at 2+ ---
check('one active parent -> no energy gauge', energyGauge(solo) === '');
check('leaf-only -> no energy gauge', energyGauge(leafOnly) === '');
check('two active parents -> gauge shown', energyGauge(two).indexOf('engauge') >= 0);

// --- energy sum counts only ACTIVE parents' energy ---
check('energySum sums active-parent energy', energySum(two) === 70, String(energySum(two)));
const withIdle = [P('p1', 50), K('c1', 'p1', 'in_progress'), P('p2', 20), K('c2', 'p2', 'in_progress'), P('p3', 90), K('c3', 'p3', 'backlog')];
check('inactive parent energy excluded', energySum(withIdle) === 70, String(energySum(withIdle)));

// --- 100% cap: over-capacity warns ---
const over = [P('p1', 70), K('c1', 'p1', 'in_progress'), P('p2', 60), K('c2', 'p2', 'in_progress')];
check('sum 130 > 100 -> over class', energyGauge(over).indexOf('engauge over') >= 0, String(energySum(over)));
check('over -> shows 초과 warning', energyGauge(over).indexOf('초과') >= 0);
const okCap = [P('p1', 60), K('c1', 'p1', 'in_progress'), P('p2', 30), K('c2', 'p2', 'in_progress')];
check('sum 90 <= 100 -> no over class', energyGauge(okCap).indexOf(' over') < 0);
check('under cap -> shows 남은 10%', energyGauge(okCap).indexOf('남은 10%') >= 0);

// --- ROI = value / tokens(K), banded (computed on the parent goal) ---
check('roiOf null when no tokens', roiOf(P('x', 0, 0, 50)) === null);
check('roiOf 100v / 50K = 2.0', roiOf(P('x', 0, 50, 100)) === 2.0);
check('high ROI -> hi band', roiClass(roiOf(P('x', 0, 50, 100))) === 'hi');     // 2.0 >= 1.0
check('mid ROI -> mid band', roiClass(roiOf(P('x', 0, 100, 60))) === 'mid');     // 0.6 in [0.4,1.0)
check('token burn -> lo band', roiClass(roiOf(P('x', 0, 1000, 50))) === 'lo');   // 0.05 < 0.4
check('roiClass null -> empty', roiClass(null) === '');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
