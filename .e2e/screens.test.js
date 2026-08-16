// E2E for the 화면 카탈로그 tab, bound to the REAL source (BGMPlayerContent.swift).
// Extracts the screens block (loadScreens/renderScreens/renderScSitemap/scSave/… + consts)
// and asserts BOTH views:
//   사이트맵 (default): tree renders pages/subpages/states with coverage badges, node
//   selection shows matched screenshots (catalog keys joined by mode/path/view/flag,
//   query KEYS stripped so /goal?n matches the /goal page node)
//   그리드: SCR cards, status filtering, summary counts, note/status save round-trip.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/BGMPlayerContent.swift', 'utf8');
function slice(from, to) {
  const a = SRC.indexOf(from); const b = SRC.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('extract ' + from);
  return SRC.slice(a, b);
}
const JS = slice('let _scList=null, _scFilter=', 'function initActions(){');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got).slice(0, 200));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ---- stubs shared with the page (helpers the block reuses) ----
const els = {};
function el(id) {
  if (!els[id]) els[id] = { id, innerHTML: '', textContent: '', value: '', src: '',
                            style: {}, classList: { toggle() {}, add() {}, remove() {} } };
  return els[id];
}
global.window = global;
global.$ = id => el(id);
global.document = { getElementById: id => el(id) };
global.esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
global.actPad = n => (n < 10 ? '0' + n : '' + n);
global.CMTimeFilter = { parts: t => { const d = new Date(t); return { y: d.getFullYear(), mo: d.getMonth() + 1, d: d.getDate(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds() }; } };
global.vtPage = pg => { const p = (pg || '').split('?')[0]; return ({ '/': '대시보드', '/goal': '목표 상세' })[p] || p; };

// Synchronous thenable fetch: GETs resolve to __data (so loadScreens injects the fixture
// through the REAL code path — the eval'd `let _scList` is not reachable from this scope).
// __data carries BOTH feeds; loadScreens reads .screens from the first fetch and .pages
// from the second.
global.__fetches = [];
global.__data = null;
global.fetch = (url, opts) => {
  global.__fetches.push({ url, opts });
  // Flatten thenables like a real Promise, so `fetch().then(() => fetch().then(...))` chains.
  const mk = v => ({
    then(f) { const r = f(v); return (r && typeof r.then === 'function') ? r : mk(r); },
    catch() { return this; },
  });
  return mk({ json: () => global.__data });
};

eval(JS);

const T = Date.parse('2026-07-12T10:00:00');
global.__data = {
  screens: [
    { id: 'SCR-0001', key: 'dashboard|/|goals|zen,reward', mode: 'dashboard', page: '/', view: 'goals',
      flags: 'zen,reward', w: 1040, h: 720, firstSeen: T, lastSeen: T + 60000, count: 5,
      shotAt: T + 1000, file: 'SCR-0001.png', note: '', status: '' },
    { id: 'SCR-0002', key: 'dashboard|/goal?n||', mode: 'dashboard', page: '/goal?n', view: '',
      flags: '', w: 1040, h: 720, firstSeen: T, lastSeen: T, count: 2,
      shotAt: 0, file: '', note: '여백 좁음', status: 'fix' },
  ],
  // sitemap feed (same object serves both fetches in this stub)
  generatedAt: '2026-07-12T21:00:00+09:00', commit: 'abcdef1234567890',
  flagLabels: { zen: '젠 (보드 접힘)', reward: '수확 대기 (완주 오브)' },
  pages: [
    { id: 'dashboard', title: '대시보드', path: '/', mode: 'dashboard', desc: '메인 보드',
      src: 'Sources/ConditionMate/Dashboard/DashboardContent.swift',
      children: [{ id: 'dashboard-goals', title: '목록', view: 'goals' }],
      states: ['zen', 'reward'] },
    { id: 'goal', title: '목표 상세', path: '/goal', mode: 'dashboard', desc: 'goal 하나의 페이지',
      children: [], states: [] },
  ],
};

// ---- 1) Default = 사이트맵 view: tree + coverage + first-node detail ----
loadScreens();
const tree = el('scTree').innerHTML;
check('tree renders both pages', [tree.includes('대시보드'), tree.includes('목표 상세')], [true, true]);
check('tree renders subpage + state rows', [tree.includes('목록'), tree.includes('수확 대기')], [true, true]);
check('coverage summary counts covered nodes', tree.includes('커버리지'), true);
check('sitemap commit stamp shown', tree.includes('abcdef12'), true);
check('default selection shows page detail', el('scNode').innerHTML.includes('메인 보드'), true);

// ---- 2) Node selection joins catalog by match vocabulary ----
scSelect('dashboard~reward');                       // state node: flags must contain 'reward'
check('reward state node matches SCR-0001', el('scNode').innerHTML.includes('SCR-0001'), true);
scSelect('dashboard-goals');                        // view node: view must equal 'goals'
check('view node matches SCR-0001', el('scNode').innerHTML.includes('SCR-0001'), true);
scSelect('goal');                                   // page node: query keys stripped (/goal?n → /goal)
const goalDetail = el('scNode').innerHTML;
check('goal page matches SCR-0002 (query keys stripped)',
      [goalDetail.includes('SCR-0002'), goalDetail.includes('SCR-0001')], [true, false]);
check('uncaptured state shows the pending placeholder', goalDetail.includes('스크린샷 대기 중'), true);

// ---- 3) 그리드 view: cards, filter, summary ----
setScView('grid');
const html = el('scGrid').innerHTML;
check('grid renders both states', [html.includes('SCR-0001'), html.includes('SCR-0002')], [true, true]);
check('captured state shows its screenshot url', html.includes('/api/debug/screens/img?id=SCR-0001'), true);
check('flags render as Korean chips', [html.includes('젠(보드 접힘)'), html.includes('수확 대기')], [true, true]);
check('summary counts states/shots/fix', el('scSummary').textContent, '화면 상태 2개 · 스크린샷 1장 · 개선필요 1개');
setScFilter('fix');
const fixed = el('scGrid').innerHTML;
check('fix filter keeps only SCR-0002', [fixed.includes('SCR-0002'), fixed.includes('SCR-0001')], [true, false]);
setScFilter('all');

// ---- 4) Save round-trip: posts note+status and re-renders local state ----
el('scNote-SCR-0001').value = '수확 화면 대비 개선';
el('scStatus-SCR-0001').value = 'review';
scSave('SCR-0001');
const post = global.__fetches.find(f => f.url === '/api/debug/screens/note');
check('save posts note+status', post && JSON.parse(post.opts.body),
      { id: 'SCR-0001', note: '수확 화면 대비 개선', status: 'review' });
check('save updates the local entry (re-rendered note)',
      el('scGrid').innerHTML.includes('수확 화면 대비 개선'), true);

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
