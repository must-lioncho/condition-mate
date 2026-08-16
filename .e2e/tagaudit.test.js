// E2E for the bgm태깅관리 per-track expansion (BGMACT-8 곡단위 확장). Bound to REAL
// source: extracts esc / arcMini / loadTagAudit / renderTagAudit (+ the ARC_KO map)
// from BGMPlayerContent.swift and runs them against a stub DOM + stub fetch shaped
// like the real /api/bgm/list response (tracks[] now carrying arc/tier/purpose,
// themes[] carrying the arc distribution object). Asserts:
//   - theme rows render collapsed by default, arc mini summary drops zeros
//   - ambient-only themes read "앰비언트 N"; untagged themes show no mini summary
//   - clicking a theme head expands per-track rows (제목 · BPM · arc 배지 · tier ·
//     purpose); clicking again collapses; other themes stay collapsed
//   - bpmResolved:false renders "—" instead of a number
//   - untagged tracks (no tags file) quietly render 제목 · BPM only — no badge, no banner
//   - fetch failure only logs (quiet), never throws
//   - arc badge CSS stays in neutral hues (no red/green traffic-light colors)
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/BGMPlayerContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
// ARC_KO is a module-level const in source; re-emit as var so it leaks out of eval.
const arcKoM = SRC.match(/const ARC_KO=(\{[^}]*\});/);
if (!arcKoM) throw new Error('no ARC_KO');

// ---- stub DOM ----
function el() {
  return {
    className: '', innerHTML: '', style: {}, children: [], onclick: null,
    appendChild(c) { this.children.push(c); },
    set textContent(v) { this.innerHTML = v; }, get textContent() { return this.innerHTML; }
  };
}
const ids = { tagStats: el(), tagThemes: el() };
// host.innerHTML="" must also clear appended children, like a real DOM node.
ids.tagThemes = new Proxy(el(), {
  set(t, k, v) { if (k === 'innerHTML' && v === '') t.children.length = 0; t[k] = v; return true; }
});
global.$ = id => ids[id];
global.document = { createElement: () => el() };

var _tagAudit = null, _tagOpen = null;
// loadTagAudit is declared `async function` in source; fn() slices from the
// `function` keyword, so restore the async modifier for the eval'd declaration.
eval('var ARC_KO=' + arcKoM[1] + ';\n' + fn('esc') + '\n' + fn('arcMini') + '\n'
  + 'async ' + fn('loadTagAudit') + '\n' + fn('renderTagAudit'));

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

// ---- sample /api/bgm/list (real response shape) ----
const J = {
  tracks: [
    { id: 0, title: 'Beyond the Horizon', bpm: 114, theme: 'challenge', bpmResolved: true, arc: 'peak', tier: '집중', purpose: '전·집중 — 마감 스퍼트' },
    { id: 1, title: 'HBM', bpm: 102, theme: 'challenge', bpmResolved: true, arc: 'intro', tier: '집중', purpose: '기·집중 — 시동' },
    { id: 2, title: 'Untimed Sprint', bpm: 110, theme: 'challenge', bpmResolved: false, arc: 'build', tier: '초집중', purpose: '승·초집중' },
    { id: 3, title: 'Rain A', bpm: 110, theme: 'heavy_rain', bpmResolved: false, arc: 'ambient', tier: '', purpose: '폭우 앰비언트' },
    { id: 4, title: 'Rain B', bpm: 110, theme: 'heavy_rain', bpmResolved: false, arc: 'ambient', tier: '', purpose: '폭우 앰비언트' },
    { id: 5, title: 'Office Plain', bpm: 120, theme: 'office', bpmResolved: true, arc: '', tier: '', purpose: '' }
  ],
  themes: [
    { name: 'challenge', count: 3, resolved: 2, fallback: 1, minBpm: 102, maxBpm: 114, purpose: '마감 스퍼트 추진 — 초집중', arc: { intro: 1, build: 1, peak: 1, resolve: 0, ambient: 0 } },
    { name: 'heavy_rain', count: 2, resolved: 0, fallback: 2, minBpm: 0, maxBpm: 0, purpose: '폭우 앰비언트(무비트)', arc: { intro: 0, build: 0, peak: 0, resolve: 0, ambient: 2 } },
    { name: 'office', count: 1, resolved: 1, fallback: 0, minBpm: 120, maxBpm: 120, purpose: '업무 적응 본진', arc: { intro: 0, build: 0, peak: 0, resolve: 0, ambient: 0 } }
  ]
};

(async () => {
  // --- arcMini: zeros dropped, ambient-only wording, empty when untagged ---
  check('arcMini drops zero beats', arcMini(J.themes[0].arc) === '기1·승1·전1', arcMini(J.themes[0].arc));
  check('arcMini ambient-only', arcMini(J.themes[1].arc) === '앰비언트 2', arcMini(J.themes[1].arc));
  check('arcMini all-zero -> empty', arcMini(J.themes[2].arc) === '');
  check('arcMini mixed beats+ambient', arcMini({ intro: 2, build: 0, peak: 1, resolve: 0, ambient: 3 }) === '기2·전1·앰비언트3');

  // --- initial render via loadTagAudit (fetch stub) ---
  global.fetch = async () => ({ json: async () => J });
  await loadTagAudit(true);
  const rows = () => ids.tagThemes.children;
  const rowOf = name => rows().find(r => r.children[0].innerHTML.indexOf('tgname">' + name) >= 0);
  check('3 theme rows', rows().length === 3, String(rows().length));
  check('stats totals 6/3/3/3', ids.tagStats.innerHTML.indexOf('>6<') >= 0 && ids.tagStats.innerHTML.indexOf('테마 수') >= 0);
  check('default collapsed (no .open)', rows().every(r => r.className.indexOf('open') < 0));
  check('default no track rows', rows().every(r => r.children.every(c => c.className !== 'tgtracks')));
  check('challenge head carries arc mini', rowOf('challenge').children[0].innerHTML.indexOf('기1·승1·전1') >= 0);
  check('heavy_rain head carries 앰비언트 2', rowOf('heavy_rain').children[0].innerHTML.indexOf('앰비언트 2') >= 0);
  check('office head has NO arc mini span', rowOf('office').children[0].innerHTML.indexOf('tgarcs') < 0);
  check('theme purpose line kept', rowOf('challenge').children.some(c => c.className === 'tgpurpose'));

  // --- expand challenge ---
  rowOf('challenge').children[0].onclick();
  const ch = rowOf('challenge');
  check('clicked row gains .open', ch.className.indexOf('open') >= 0, ch.className);
  check('others stay collapsed', rowOf('office').className.indexOf('open') < 0);
  const box = ch.children.find(c => c.className === 'tgtracks');
  check('track box rendered', !!box);
  check('3 track rows for challenge', box.children.length === 3, String(box.children.length));
  const t0 = box.children[0].innerHTML;
  check('track row: title', t0.indexOf('Beyond the Horizon') >= 0);
  check('track row: resolved BPM shown', t0.indexOf('114 BPM') >= 0);
  check('track row: arc badge 전 (peak)', t0.indexOf('tgab peak') >= 0 && t0.indexOf('>전<') >= 0);
  check('track row: tier', t0.indexOf('집중') >= 0);
  check('track row: purpose', t0.indexOf('마감 스퍼트') >= 0);
  const tFb = box.children[2].innerHTML;
  check('bpmResolved:false -> —', tFb.indexOf('—') >= 0 && tFb.indexOf('110') < 0, tFb);
  check('build badge 승', tFb.indexOf('tgab build') >= 0 && tFb.indexOf('>승<') >= 0);

  // --- ambient rows: badge 앰비언트, no tier span ---
  rowOf('heavy_rain').children[0].onclick();
  const hr = rowOf('heavy_rain').children.find(c => c.className === 'tgtracks');
  check('ambient badge', hr.children[0].innerHTML.indexOf('tgab ambient') >= 0 && hr.children[0].innerHTML.indexOf('앰비언트') >= 0);
  check('ambient has no tier span', hr.children[0].innerHTML.indexOf('tgtier') < 0);

  // --- untagged track (tags file absent): quietly title + BPM only ---
  rowOf('office').children[0].onclick();
  const of = rowOf('office').children.find(c => c.className === 'tgtracks').children[0].innerHTML;
  check('untagged: title+BPM only', of.indexOf('Office Plain') >= 0 && of.indexOf('120 BPM') >= 0);
  check('untagged: no badge/tier/purpose spans', of.indexOf('tgab') < 0 && of.indexOf('tgtier') < 0 && of.indexOf('tgtp') < 0);

  // --- collapse again ---
  rowOf('challenge').children[0].onclick();
  check('second click collapses', rowOf('challenge').className.indexOf('open') < 0);
  check('collapsed row drops track rows', !rowOf('challenge').children.some(c => c.className === 'tgtracks'));
  check('heavy_rain expansion survives re-render', rowOf('heavy_rain').className.indexOf('open') >= 0);

  // --- quiet failure: fetch error only logs, no throw, old render kept ---
  global.fetch = async () => { throw new Error('down'); };
  let threw = false;
  try { await loadTagAudit(true); } catch (e) { threw = true; }
  check('fetch failure is quiet (no throw)', !threw);
  check('failure keeps previous rows', rows().length === 3);

  // --- neutral hues only: the arc badge CSS block bans red/green ---
  const cssStart = SRC.indexOf('.tgab{'), cssEnd = SRC.indexOf('.tgab.ambient');
  const css = SRC.slice(cssStart, SRC.indexOf('}', cssEnd));
  check('tgab CSS extracted', cssStart > 0 && css.length > 0);
  const hexes = css.match(/#[0-9a-f]{6}/gi) || [];
  const trafficLight = hexes.filter(h => {
    const r = parseInt(h.slice(1, 3), 16), g = parseInt(h.slice(3, 5), 16), b = parseInt(h.slice(5, 7), 16);
    return (g > r * 1.4 && g > b * 1.4) || (r > g * 1.8 && r > b * 1.8); // dominant green / red
  });
  check('no traffic-light hues in arc badges', trafficLight.length === 0, trafficLight.join(','));

  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
