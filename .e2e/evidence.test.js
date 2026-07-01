// E2E for completion-evidence logic. Bound to REAL source: extracts the pure
// helpers (esc / goalKids / derivedStatus / isDoneGoal / evCount / evItem / evMd)
// from DashboardContent.swift and asserts:
//   - evCount counts attached evidence
//   - isDoneGoal: a done leaf OR a parent whose children are all done
//   - evItem renders a file as a download link (📄) and a link as a new-tab anchor (🔗)
//   - evMd: files list name only (their /evidence URL is dashboard-local), links keep the URL
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
eval(fn('esc') + '\n' + fn('goalKids') + '\n' + fn('derivedStatus') + '\n'
  + fn('isDoneGoal') + '\n' + fn('evCount') + '\n' + fn('evItem') + '\n' + fn('evMd'));

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const G = (id, status, parent, evidence) => ({ id, seq: 0, text: id, parent: parent || '', status: status || 'backlog', evidence: evidence || [] });
const LINK = (id, href, title) => ({ id, kind: 'link', title: title || '', href });
const FILE = (id, href, title) => ({ id, kind: 'file', title: title || '', href });

// --- evCount ---
check('evCount 0 when none', evCount(G('a')) === 0);
check('evCount counts items', evCount(G('a', 'done', '', [LINK('e1', 'http://x'), FILE('e2', '/evidence/a/e2')])) === 2);

// --- isDoneGoal: leaf done ---
const lone = [G('a', 'done'), G('b', 'in_progress')];
check('done leaf -> isDoneGoal', isDoneGoal(lone[0], lone) === true);
check('in_progress leaf -> not done', isDoneGoal(lone[1], lone) === false);

// --- isDoneGoal: parent rolls up from children (every child done) ---
const fam = [G('p', 'backlog'), G('c1', 'done', 'p'), G('c2', 'done', 'p')];
check('parent w/ all children done -> done', isDoneGoal(fam[0], fam) === true);
const fam2 = [G('p', 'backlog'), G('c1', 'done', 'p'), G('c2', 'in_progress', 'p')];
check('parent w/ a child not done -> not done', isDoneGoal(fam2[0], fam2) === false);

// --- evItem rendering: file vs link ---
const g = G('a');
const fileHtml = evItem(g, FILE('e1', '/evidence/a/e1', 'report.pdf'));
check('file item is a download anchor', fileHtml.indexOf('download') >= 0 && fileHtml.indexOf('/evidence/a/e1') >= 0);
check('file item shows 📄 + title', fileHtml.indexOf('📄') >= 0 && fileHtml.indexOf('report.pdf') >= 0);
check('file item has remove button for its id', fileHtml.indexOf("removeEvidence('a','e1')") >= 0);
const linkHtml = evItem(g, LINK('e2', 'https://ex.com/x', '근거 문서'));
check('link item opens in new tab', linkHtml.indexOf('target="_blank"') >= 0 && linkHtml.indexOf('https://ex.com/x') >= 0);
check('link item shows 🔗 + title', linkHtml.indexOf('🔗') >= 0 && linkHtml.indexOf('근거 문서') >= 0);

// --- evItem escapes hostile titles (no raw tag injection) ---
const xss = evItem(g, LINK('e3', 'https://ex.com', '<script>'));
check('evItem escapes title', xss.indexOf('<script>') < 0 && xss.indexOf('&lt;script&gt;') >= 0);

// --- evMd: portable text (file = name only, link = url kept) ---
const md = evMd(G('a', 'done', '', [FILE('e1', '/evidence/a/e1', 'report.pdf'), LINK('e2', 'https://ex.com/x', 'doc')]));
check('md file = name, no local url', md.indexOf('📄 report.pdf') >= 0 && md.indexOf('/evidence/a/e1') < 0);
check('md link keeps url', md.indexOf('🔗 doc https://ex.com/x') >= 0);
check('md empty when none', evMd(G('a')) === '');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
