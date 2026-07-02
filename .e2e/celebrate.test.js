// E2E for the completion celebration (check sweep + floating +Nv). Bound to REAL
// source: extracts setStatus/celebrateDone/floatValue/VGAIN from DashboardContent.swift
// and runs them against a real Chromium DOM to assert the animation + deferred commit.
const { chromium } = require('playwright');
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
const VGAIN = (SRC.match(/const VGAIN='([^']+)'/) || [])[1];
const realJs = "const VGAIN='" + VGAIN + "';\nlet _actx=null;\n" + fn('setStatus') + '\n' + fn('celebrateDone') + '\n' + fn('floatValue') + '\n' + fn('_bell') + '\n' + fn('_clack') + '\n' + fn('playDing');

const html = `<!doctype html><meta charset=utf-8>
<style>.gstrike{position:absolute;left:0;height:2px;width:0;background:#36c08a;transition:width .45s}.gstrike.on{width:100%}
.vfloat{position:fixed;opacity:0;transition:opacity 1s,transform 1s}</style>
<body>
<div class="goal" id="row"><span class="g" style="position:relative">리포트작성</span>
<button id="done" onclick="setStatus('uuid-1','done',event)">완료</button></div>
<script>
window.__posts=[]; window.__notes=[]; window.__src=0; window.__fetch=[];
function post(path,obj){ window.__posts.push({path,obj,t:Date.now()}); return Promise.resolve(); }
window.fetch=function(u){ window.__fetch.push(u); return Promise.resolve({ok:true}); };
// Stub Web Audio to capture the ka-ching structure without real output.
class FakeOsc{ constructor(){ this.frequency={value:0}; } connect(x){return x;} start(){} stop(){} }
class FakeGain{ constructor(){ this.gain={setValueAtTime(){},exponentialRampToValueAtTime(){}}; } connect(x){return x;} }
class FakeBuf{ constructor(n){ this._d=new Float32Array(n);} getChannelData(){return this._d;} }
class FakeSrc{ connect(x){return x;} start(){} stop(){} }
class FakeBQ{ constructor(){ this.frequency={value:0}; this.Q={value:0}; this.type=''; } connect(x){return x;} }
window.AudioContext=class{ constructor(){ this.currentTime=0; this.state='running'; this.destination={}; this.sampleRate=44100; }
  resume(){}
  createOscillator(){ const o=new FakeOsc(); window.__notes.push(o); return o; }
  createGain(){ return new FakeGain(); }
  createBuffer(ch,n){ return new FakeBuf(n); }
  createBufferSource(){ window.__src++; return new FakeSrc(); }
  createBiquadFilter(){ return new FakeBQ(); } };
${realJs}
</script></body>`;

const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(html);

  check('VGAIN is 0.5 (v, not hours)', VGAIN === '0.5', VGAIN);

  const clickAt = await page.evaluate(() => { document.getElementById('done').click(); return Date.now(); });

  // Immediately after click: sweep + float present, but NO post yet (deferred ~480ms).
  const immediate = await page.evaluate(() => ({
    celebrate: document.getElementById('row').classList.contains('celebrate'),
    hasStrike: !!document.querySelector('.gstrike'),
    floatText: (document.querySelector('.vfloat') || {}).textContent || null,
    posts: window.__posts.length,
  }));
  check('row gets celebrate class', immediate.celebrate);
  check('strike sweep element added', immediate.hasStrike);
  check('floating value shows +0.5v', immediate.floatText === '+0.5v', immediate.floatText);
  check('commit is deferred (no post yet)', immediate.posts === 0, 'posts=' + immediate.posts);

  // Ka-ching: drawer clack (noise source) + two metallic bells (4 inharmonic partials each).
  const audio = await page.evaluate(() => ({ osc: window.__notes.map(o => Math.round(o.frequency.value)), src: window.__src }));
  check('ka-ching: drawer clack via noise source', audio.src === 1, 'src=' + audio.src);
  check('ka-ching: 8 bell partials (2 bells x 4)', audio.osc.length === 8, 'osc=' + audio.osc.length);
  check('ka-ching: bell fundamentals 1319 + 1760', audio.osc.includes(1319) && audio.osc.includes(1760), JSON.stringify(audio.osc));

  // BGM ducking: completion sound requests /api/duck so the native BGM dips under it.
  const fetched = await page.evaluate(() => window.__fetch.slice());
  check('requests /api/duck to lower BGM', fetched.includes('/api/duck'), JSON.stringify(fetched));

  // Double-click is debounced: still celebrating -> no extra sound, no extra commit.
  await page.evaluate(() => { window.__notes = []; window.__src = 0; document.getElementById('done').click(); });
  const dbl = await page.evaluate(() => window.__notes.length + window.__src);
  check('double-click debounced (no extra sound)', dbl === 0, 'extra=' + dbl);

  // After the sweep window: the done status is committed exactly once.
  await page.waitForTimeout(700);
  const after = await page.evaluate(() => window.__posts.map(p => ({ path: p.path, status: p.obj.status, id: p.obj.id })));
  check('commits done once after sweep', eq(after, [{ path: '/api/goal/status', status: 'done', id: 'uuid-1' }]), JSON.stringify(after));

  // Strike animates to full width (sweep completed).
  const strikeFull = await page.evaluate(() => document.querySelector('.gstrike').classList.contains('on'));
  check('strike reached full width', strikeFull);

  // Floating value is cleaned up (removed from DOM) after the animation.
  await page.waitForTimeout(700);
  const floatGone = await page.evaluate(() => !document.querySelector('.vfloat'));
  check('floating value cleaned up', floatGone);

  // Non-done status posts immediately, no celebration.
  await page.evaluate(() => { window.__posts = []; setStatus('uuid-1', 'in_progress', { target: document.getElementById('done') }); });
  const prog = await page.evaluate(() => ({ posts: window.__posts.length, status: (window.__posts[0] || {}).obj && window.__posts[0].obj.status }));
  check('in_progress commits immediately (no defer)', prog.posts === 1 && prog.status === 'in_progress');

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
